# frozen_string_literal: true

# Used to process select sellers manually
# For the rest, we'll use `seller_refund_policy_disabled_for_all` feature flag to override User#refund_policy_enabled flag
#

class Onetime::RevertToProductLevelRefundPolicies < Onetime::Base
  LAST_PROCESSED_ID_KEY = :last_processed_seller_for_revert_to_product_level_refund_policy_id

  attr_reader :seller_ids, :invalid_seller_ids

  def self.reset_last_processed_id
    $redis.del(LAST_PROCESSED_ID_KEY)
  end

  def initialize(seller_ids: [])
    raise ArgumentError, "Seller ids not found" if seller_ids.blank?

    @seller_ids = seller_ids
    @invalid_seller_ids = []
    @last_processed_index = ($redis.get(LAST_PROCESSED_ID_KEY) || -1).to_i
  end

  def process
    ReplicaLagWatcher.watch()
    seller_ids.each_with_index do |seller_id, index|
      if index <= @last_processed_index
        Rails.logger.info "Seller: #{seller_id} (#{index + 1}/#{seller_ids.size}): skipped (already processed in previous run)"
        next
      end

      message_prefix = "Seller: #{seller_id} (#{index + 1}/#{seller_ids.size})"
      seller = User.find(seller_id)
      if !seller.account_active?
        Rails.logger.info "#{message_prefix}: skipped (not active)"
        next
      end

      if seller.refund_policy_enabled?
        seller.with_lock do
          seller.update!(refund_policy_enabled: false)
          ContactingCreatorMailer.product_level_refund_policies_reverted(seller.id).deliver_later
          Rails.logger.info "#{message_prefix}: processed and email sent"
        end
      else
        Rails.logger.info "#{message_prefix}: skipped (already processed)"
        next
      end

      $redis.set(LAST_PROCESSED_ID_KEY, index, ex: 1.month)
    rescue => e
      Rails.logger.info "#{message_prefix}: error: #{e.message}"
      invalid_seller_ids << { seller_id => e.message }
    end
  end
end
