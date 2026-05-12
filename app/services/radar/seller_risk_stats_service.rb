# frozen_string_literal: true

module Radar
  class SellerRiskStatsService
    LOOKBACK_PERIOD = 90.days

    attr_reader :user

    def initialize(user)
      @user = user
    end

    def stats
      {
        successful_purchases: successful_purchases_count,
        efw_count: efw_grouped_counts.values.sum,
        efw_by_fraud_type: efw_grouped_counts.each_with_object(Hash.new(0)) { |((_, type), count), h| h[type] += count },
        efw_with_elevated_risk: efw_grouped_counts.sum { |(risk, _), count| risk == EarlyFraudWarning::CHARGE_RISK_LEVEL_ELEVATED ? count : 0 },
        efw_with_highest_risk: efw_grouped_counts.sum { |(risk, _), count| risk == EarlyFraudWarning::CHARGE_RISK_LEVEL_HIGHEST ? count : 0 },
        dispute_count: dispute_count,
        dispute_rate: dispute_rate
      }
    end

    def recent_efws(limit = 5)
      efws.includes(:purchase, :charge).order(created_at: :desc).limit(limit).map do |efw|
        {
          purchase_id: efw.purchase&.external_id || (efw.charge && "CH-#{efw.charge.external_id}"),
          fraud_type: efw.fraud_type,
          charge_risk_level: efw.charge_risk_level,
          resolution: efw.resolution,
          created_at: efw.created_at
        }
      end
    end

    private
      def cutoff_date
        @cutoff_date ||= LOOKBACK_PERIOD.ago
      end

      def successful_purchases_count
        @successful_purchases_count ||= user.sales.successful.where("purchases.created_at >= ?", cutoff_date).count
      end

      def efws
        @efws ||= begin
          purchase_scope = EarlyFraudWarning
            .joins(:purchase)
            .where(purchases: { seller_id: user.id })
          charge_scope = EarlyFraudWarning
            .joins(:charge)
            .where(charges: { seller_id: user.id })
          EarlyFraudWarning
            .where(id: purchase_scope.select(:id))
            .or(EarlyFraudWarning.where(id: charge_scope.select(:id)))
            .where("purchase_early_fraud_warnings.created_at >= ?", cutoff_date)
        end
      end

      def dispute_count
        @dispute_count ||= Dispute
          .where(seller_id: user.id)
          .where.not(state: "won")
          .where("disputes.created_at >= ?", cutoff_date)
          .count
      end

      def dispute_rate
        return 0.0 if successful_purchases_count.zero?

        (dispute_count.to_f / successful_purchases_count * 100).round(2)
      end

      def efw_grouped_counts
        @efw_grouped_counts ||= efws.group(:charge_risk_level, :fraud_type).count
      end
  end
end
