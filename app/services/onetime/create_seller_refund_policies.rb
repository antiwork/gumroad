# frozen_string_literal: true

class Onetime::CreateSellerRefundPolicies < Onetime::Base
  LAST_PROCESSED_SELLER_ID_KEY = :last_processed_seller_for_refund_policy_id

  def self.reset_last_processed_seller_id
    $redis.del(LAST_PROCESSED_SELLER_ID_KEY)
  end

  def initialize(max_id: User.last!.id)
    @max_id = max_id
  end

  def process
    invalid_seller_ids = []
    eligible_sellers.find_in_batches do |batch|
      ReplicaLagWatcher.watch
      Rails.logger.info "Processing sellers #{batch.first.id} to #{batch.last.id}"

      batch.each do |seller|
        seller.create_refund_policy!
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
      User.left_joins(:refund_policy)
            .where(refund_policies: { id: nil })
            .where(id: first_seller_id..max_id)
    end

    def first_eligible_seller_id
      User.first!.id
    end
end
