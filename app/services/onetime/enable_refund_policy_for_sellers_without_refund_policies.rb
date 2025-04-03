# frozen_string_literal: true

class Onetime::EnableRefundPolicyForSellersWithoutRefundPolicies < Onetime::Base
  LAST_PROCESSED_SELLER_ID_KEY = :last_processed_existing_seller_without_refund_policies_id

  def self.reset_last_processed_seller_id
    $redis.del(LAST_PROCESSED_SELLER_ID_KEY)
  end

  def initialize(max_id: User.last!.id)
    @max_id = max_id
  end

  def process
    invalid_seller_ids = []
    ReplicaLagWatcher.watch
    eligible_sellers.find_in_batches do |batch|
      Rails.logger.info "Processing sellers #{batch.first.id} to #{batch.last.id}"

      batch.each do |seller|
        next if seller.refund_policy_enabled?
        next if seller.product_refund_policies.any?

        update_invalid_seller_due_to_payout_threshold_if_needed!(seller)
        seller.update!(refund_policy_enabled: true)
      rescue => e
        invalid_seller_ids << { seller.id => e.message }
      end

      $redis.set(LAST_PROCESSED_SELLER_ID_KEY, batch.last.id, ex: 2.months)
    end

    Rails.logger.info "Invalid seller ids: #{invalid_seller_ids}" if invalid_seller_ids.any?
  end

  private
    attr_reader :max_id

    def eligible_sellers
      first_seller_id = [first_eligible_seller_id, $redis.get(LAST_PROCESSED_SELLER_ID_KEY).to_i + 1].max
      User.not_refund_policy_enabled.where(id: first_seller_id..max_id)
    end

    def first_eligible_seller_id
      User.first!.id
    end

    def update_invalid_seller_due_to_payout_threshold_if_needed!(seller)
      return if seller.valid?

      full_messages = seller.errors.full_messages
      return unless full_messages.one? && full_messages.first == "Your payout threshold must be greater than the minimum payout amount"

      seller.update!(payout_threshold_cents: seller.minimum_payout_threshold_cents)
      Rails.logger.info "Updated payout threshold for seller #{seller.id} to #{seller.minimum_payout_threshold_cents}"
    end
end
