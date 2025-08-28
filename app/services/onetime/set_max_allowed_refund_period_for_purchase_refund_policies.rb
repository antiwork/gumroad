# frozen_string_literal: true

class Onetime::SetMaxAllowedRefundPeriodForPurchaseRefundPolicies < Onetime::Base
  LAST_PROCESSED_ID_KEY = :last_processed_id

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
        next if purchase_refund_policy.max_refund_period_in_days.present?

        max_refund_period_in_days = purchase_refund_policy.determine_max_refund_period_in_days
        if max_refund_period_in_days.nil?
          Rails.logger.debug("No exact match found for title '#{purchase_refund_policy.title}', skipping")
          next
        end

        begin
          purchase_refund_policy.with_lock do
            purchase_refund_policy.update!(max_refund_period_in_days: max_refund_period_in_days)
            Rails.logger.info "PurchaseRefundPolicy: #{purchase_refund_policy.id}: updated with max allowed refund period of #{max_refund_period_in_days} days"
          end
        rescue => e
          invalid_policy_ids << { purchase_refund_policy.id => e.message }
        end
      end

      $redis.set(LAST_PROCESSED_ID_KEY, batch.last.id, ex: 1.month)
    end

    Rails.logger.info "Invalid purchase refund policy ids: #{invalid_policy_ids}" if invalid_policy_ids.any?
  end

  private
    attr_reader :max_id

    def eligible_purchase_refund_policies
      first_policy_id = [first_eligible_policy_id, $redis.get(LAST_PROCESSED_ID_KEY).to_i + 1].max
      PurchaseRefundPolicy.where(id: first_policy_id..max_id)
    end

    def first_eligible_policy_id
      PurchaseRefundPolicy.first!.id
    end
end
