# frozen_string_literal: true

# Finds every seller whose payouts are currently held because Stripe disabled payouts on their
# connected account, and queues a per-seller re-check against Stripe.
#
# Why this exists: that pause is cleared only by the `account.updated` webhook
# (StripeMerchantAccountManager.handle_stripe_info_requirements), which is the single writer of
# `payouts_paused_internally` for this source and has no scheduled caller. A dropped or no-op
# delivery therefore leaves the seller paused indefinitely, with the settings banner still telling
# them to contact support, and nothing watching the divergence between Stripe's `payouts_enabled`
# and our pause state. Seen once (gumroad-private#4301): Stripe cleared the account at
# 2026-11-04T15:50:40Z, nothing on our side acted, and the seller stayed paused until support ran
# `gumroad admin payouts resume` by hand at 16:03:37Z.
#
# Candidates come from the pause comments the webhook itself writes rather than from a scan of the
# users table: the paused-payouts flag is a bit in `users.flags` with no index, while comments are
# indexed on (comment_type, commentable_type, created_at, commentable_id). Every seller ever
# Stripe-paused keeps their comment, so most candidates return on the per-seller job's first guard,
# before any Stripe call.
class ReconcileStripePayoutsPausesJob
  include Sidekiq::Job
  sidekiq_options queue: :low, lock: :until_executed, retry: 2
  include RecurringLockTtl
  recurring_lock_ttl max_attempt: 30.minutes

  BATCH_SIZE = 1_000

  def perform
    # Dedupe across the whole scan rather than per batch: one seller can carry several historical
    # Stripe pause comments and must only be enqueued once.
    seen = Set.new

    candidate_comments.find_in_batches(batch_size: BATCH_SIZE) do |batch|
      ReplicaLagWatcher.watch
      batch.each do |comment|
        next unless seen.add?(comment.commentable_id)

        ReconcileStripePayoutsPauseForSellerJob.perform_async(comment.commentable_id)
      end
    end
  end

  private
    def candidate_comments
      Comment.alive
             .with_type_payouts_paused
             .where(commentable_type: "User")
             .where(author_name: StripeMerchantAccountManager::STRIPE_PAYOUTS_SYNC_COMMENT_AUTHOR)
             .select(:id, :commentable_id)
    end
end
