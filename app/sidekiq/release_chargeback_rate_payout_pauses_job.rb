# frozen_string_literal: true

# Finds every seller whose payouts are currently held by the automatic chargeback-rate check and
# queues a per-seller re-check.
#
# Why this exists: Purchase::Blockable#pause_payouts_for_seller_based_on_chargeback_rate! sets the
# hold but nothing ever cleared it. Until this job, the only way out of a chargeback-rate pause was
# an admin resuming payouts by hand, so a seller whose rate recovered stayed held indefinitely and
# nobody was watching. Support had been telling sellers the hold would lift on its own; this is what
# makes that true.
#
# Candidates come from the probation comments the pause itself writes rather than from a scan of the
# users table: the paused-payouts flag is a bit in `users.flags` with no index, while comments are
# indexed on (comment_type, commentable_type, created_at, commentable_id), and the number of
# accounts ever caught by this check is small. Each candidate is re-checked individually because the
# rate comes from an Elasticsearch aggregation over the seller's sales.
class ReleaseChargebackRatePayoutPausesJob
  include Sidekiq::Job
  sidekiq_options queue: :low, lock: :until_executed, retry: 2

  BATCH_SIZE = 1_000

  def perform
    candidate_comments.find_in_batches(batch_size: BATCH_SIZE) do |batch|
      ReplicaLagWatcher.watch
      batch.map(&:commentable_id)
           .uniq
           .each { |user_id| ReleaseChargebackRatePayoutPauseForSellerJob.perform_async(user_id) }
    end
  end

  private
    def candidate_comments
      Comment.alive
             .with_type_on_probation
             .where(commentable_type: "User")
             .where(author_name: User::SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS[:high_chargeback_rate])
             .select(:id, :commentable_id)
    end
end
