# frozen_string_literal: true

class Onetime::NotifySellersWithRefundPolicies < Onetime::Base
  LAST_PROCESSED_ID_KEY = :last_notified_seller_for_refund_policy_id

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

        seller.with_lock do
          if seller.upcoming_refund_policy_change_email_sent?
            Rails.logger.info "Seller: #{seller.id}: skipped"
            next
          else
            seller.update!(upcoming_refund_policy_change_email_sent: true)
            ContactingCreatorMailer.upcoming_refund_policy_change(seller.id).deliver_later
            Rails.logger.info "Seller: #{seller.id}: email sent"
          end
        end
      rescue => e
        invalid_seller_ids << { seller.id => e.message }
      end

      $redis.set(LAST_PROCESSED_ID_KEY, batch.last.id, ex: 2.months)
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
