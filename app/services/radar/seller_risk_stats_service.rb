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
        total_purchases: total_purchases_count,
        efw_count: efws.count,
        efw_by_fraud_type: efw_by_fraud_type,
        efw_with_elevated_risk: efws.where(charge_risk_level: EarlyFraudWarning::CHARGE_RISK_LEVEL_ELEVATED).count,
        efw_with_highest_risk: efws.where(charge_risk_level: EarlyFraudWarning::CHARGE_RISK_LEVEL_HIGHEST).count,
        dispute_count: dispute_count,
        dispute_rate: dispute_rate
      }
    end

    def recent_efws(limit = 5)
      efws.includes(:purchase).order(created_at: :desc).limit(limit).map do |efw|
        {
          purchase_id: efw.purchase&.external_id,
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

      def total_purchases_count
        @total_purchases_count ||= user.sales.where("purchases.created_at >= ?", cutoff_date).count
      end

      def efws
        @efws ||= EarlyFraudWarning
          .joins(:purchase)
          .where(purchases: { seller_id: user.id })
          .where("purchase_early_fraud_warnings.created_at >= ?", cutoff_date)
      end

      def dispute_count
        @dispute_count ||= Dispute
          .where(seller_id: user.id)
          .where("disputes.created_at >= ?", cutoff_date)
          .count
      end

      def dispute_rate
        return 0.0 if total_purchases_count.zero?

        (dispute_count.to_f / total_purchases_count * 100).round(2)
      end

      def efw_by_fraud_type
        efws.group(:fraud_type).count
      end
  end
end
