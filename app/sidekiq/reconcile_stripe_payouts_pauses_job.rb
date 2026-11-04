# frozen_string_literal: true

# Queues a per-seller re-check for every seller with a Stripe-source payout pause. Only the
# `account.updated` webhook clears that pause, so a missed delivery would otherwise leave it stuck.
#
# Candidates come from the pause comments rather than `users.flags`: the paused-payouts bit is
# unindexed, while comments are indexed on (comment_type, commentable_type, created_at, commentable_id).
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
