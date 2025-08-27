# frozen_string_literal: true

class Onetime::BackfillPurchaseRefundPolicyMaxRefundPeriod < Onetime::Base
  LAST_PROCESSED_ID_KEY = :last_processed_purchase_refund_policy_id

  def self.reset_last_processed_id
    $redis.del(LAST_PROCESSED_ID_KEY)
  end

  def initialize(max_id: PurchaseRefundPolicy.last!.id)
    @max_id = max_id
  end

  def process
    invalid_policy_ids = []
    eligible_purchase_refund_policies.find_in_batches do |batch|
      ReplicaLagWatcher.watch
      Rails.logger.info "Processing purchase refund policies #{batch.first.id} to #{batch.last.id}"

      batch.each do |purchase_refund_policy|
        max_refund_period_in_days = determine_max_refund_period_from_title(purchase_refund_policy.title)
        purchase_refund_policy.update!(max_refund_period_in_days: max_refund_period_in_days)
        Rails.logger.info "PurchaseRefundPolicy: #{purchase_refund_policy.id}: updated with #{max_refund_period_in_days} days"
      rescue => e
        invalid_policy_ids << { purchase_refund_policy.id => e.message }
        Rails.logger.error "PurchaseRefundPolicy: #{purchase_refund_policy.id}: failed - #{e.message}"
      end

      $redis.set(LAST_PROCESSED_ID_KEY, batch.last.id, ex: 1.month)
    end

    Rails.logger.info "Invalid policy ids: #{invalid_policy_ids}" if invalid_policy_ids.any?
  end

  private
    attr_reader :max_id

    def eligible_purchase_refund_policies
      first_policy_id = [first_eligible_policy_id, $redis.get(LAST_PROCESSED_ID_KEY).to_i + 1].max
      PurchaseRefundPolicy.where(max_refund_period_in_days: nil).where(id: first_policy_id..max_id)
    end

    def first_eligible_policy_id
      PurchaseRefundPolicy.first!.id
    end

    def determine_max_refund_period_from_title(title)
      RefundPolicy::ALLOWED_REFUND_PERIODS_IN_DAYS.each do |days, expected_title|
        return days if title == expected_title
      end

      Rails.logger.warn "No exact match found for title: '#{title}', defaulting to 30 days"
      RefundPolicy::DEFAULT_REFUND_PERIOD_IN_DAYS
    end
end
