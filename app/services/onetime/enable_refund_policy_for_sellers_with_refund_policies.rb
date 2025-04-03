# frozen_string_literal: true

# About 40K sellers out of 22M have product refund policies
#
class Onetime::EnableRefundPolicyForSellersWithRefundPolicies < Onetime::Base
  LAST_PROCESSED_ID_KEY = :last_processed_seller_for_refund_policy_id

  def self.reset_last_processed_seller_id
    $redis.del(LAST_PROCESSED_ID_KEY)
  end

  def initialize(max_id: ProductRefundPolicy.last!.id)
    @max_id = max_id
  end

  def process
    invalid_seller_ids = []
    eligible_product_refund_policies.find_in_batches do |batch|
      ReplicaLagWatcher.watch
      Rails.logger.info "Processing product refund policies #{batch.first.id} to #{batch.last.id}"

      batch.each do |product_refund_policy|
        seller = product_refund_policy.seller
        if seller.refund_policy_enabled?
          Rails.logger.info "Seller: #{seller.id}: skipped"
          next
        else
          max_refund_period_in_days = seller.has_all_eligible_refund_policies_as_no_refunds? ? 0 : 30
          seller.with_lock do
            seller.refund_policy.update!(max_refund_period_in_days:)
            seller.update!(refund_policy_enabled: true)
            ContactingCreatorMailer.refund_policy_enabled_email(seller.id).deliver_later
            Rails.logger.info "Seller: #{seller.id}: processed and email sent"
          end
        end
      rescue => e
        invalid_seller_ids << { seller.id => e.message }
      end

      $redis.set(LAST_PROCESSED_ID_KEY, batch.last.id, ex: 1.month)
    end

    Rails.logger.info "Invalid seller ids: #{invalid_seller_ids}" if invalid_seller_ids.any?
  end

  private
    attr_reader :max_id

    def eligible_product_refund_policies
      first_product_refund_policy_id = [first_eligible_product_refund_policy_id, $redis.get(LAST_PROCESSED_ID_KEY).to_i + 1].max
      ProductRefundPolicy.where.not(product_id: nil).where(id: first_product_refund_policy_id..max_id)
    end

    def first_eligible_product_refund_policy_id
      ProductRefundPolicy.first!.id
    end
end
