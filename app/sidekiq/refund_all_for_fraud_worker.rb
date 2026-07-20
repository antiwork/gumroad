# frozen_string_literal: true

# Fans out one retried RefundPurchaseForFraudWorker job per refundable sale of a
# suspended seller. Enqueued by the internal admin refund_all_for_fraud endpoint
# after the confirmation handshake; the uniqueness lock makes concurrent runs
# impossible (the endpoint surfaces a duplicate enqueue as a 409).
#
# block_buyers distinguishes the two fraud scenarios: false (default) is the
# seller-fraud case where buyers are victims and must not be blocked; true is the
# buyer-fraud case (self-purchase / card-testing ring) where each buyer is blocked
# platform-wide.
class RefundAllForFraudWorker
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default, lock: :until_executed

  def self.lock_args(args)
    [args.first]
  end

  # Every successful, not-yet-fully-refunded sale that is not lost to an active
  # chargeback. Chargeback-reversed purchases are refundable and stay in scope.
  def self.refundable_purchases_for(user)
    user.sales.successful.not_fully_refunded.not_chargedback_or_chargedback_reversed
  end

  def perform(user_id, admin_user_id, block_buyers = false)
    user = User.find(user_id)
    return unless user.suspended?

    purchase_ids = self.class.refundable_purchases_for(user).ids
    purchase_ids.each do |purchase_id|
      RefundPurchaseForFraudWorker.perform_async(purchase_id, admin_user_id, block_buyers)
    end

    admin = User.find(admin_user_id)
    user.comments.create!(
      author_id: admin.id,
      author_name: admin.name_or_username,
      comment_type: Comment::COMMENT_TYPE_REFUND_ALL_FOR_FRAUD,
      content: "Bulk fraud refund initiated by #{admin.name_or_username}: " \
               "#{purchase_ids.size} #{"purchase".pluralize(purchase_ids.size)} queued for refund" \
               "#{block_buyers ? ", buyers will be blocked" : ", buyers will not be blocked"}."
    )
  end
end
