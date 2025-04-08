# frozen_string_literal: true

class Onetime::SetMaxAllowedRefundPeriodForProductRefundPolicies < Onetime::Base
  LAST_PROCESSED_ID_KEY = :last_processed_id

  def self.reset_last_processed_id
    $redis.del(LAST_PROCESSED_ID_KEY)
  end

  def initialize(max_id: ProductRefundPolicy.last!.id)
    @max_id = max_id
  end

  def process
    invalid_policy_ids = []
    eligible_product_refund_policies.find_in_batches do |batch|
      ReplicaLagWatcher.watch
      Rails.logger.info "Processing product refund policies #{batch.first.id} to #{batch.last.id}"

      batch.each do |product_refund_policy|
        next if product_refund_policy.max_refund_period_in_days.present?

        max_refund_period_in_days = product_refund_policy.determine_max_refund_period_in_days

        begin
          product_refund_policy.with_lock do
            product_refund_policy.update!(max_refund_period_in_days:)
            Rails.logger.info "ProductRefundPolicy: #{product_refund_policy.id}: updated with max allowed refund period of #{max_refund_period_in_days} days"
          end
        rescue => e
          invalid_policy_ids << { product_refund_policy.id => e.message }
        end
      end

      $redis.set(LAST_PROCESSED_ID_KEY, batch.last.id, ex: 1.month)
    end

    Rails.logger.info "Invalid product refund policy ids: #{invalid_policy_ids}" if invalid_policy_ids.any?
  end

  private
    attr_reader :max_id

    def eligible_product_refund_policies
      first_product_refund_policy_id = [first_eligible_product_refund_policy_id, $redis.get(LAST_PROCESSED_ID_KEY).to_i + 1].max
      ProductRefundPolicy.where.not(product_id: nil).where(id: first_product_refund_policy_id..max_id)
    end

    def first_eligible_product_refund_policy_id
      ProductRefundPolicy.where.not(product_id: nil).first!.id
    end
end
