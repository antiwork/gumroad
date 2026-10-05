# frozen_string_literal: true

# The stalled-blast sweep only reaches blasts up to 2 * LOOKBACK old, so blasts that never sent
# before it shipped would stay unfinished. This ends them as abandoned, by the same rule.
class Onetime::ExpireAbandonedPostEmailBlasts
  # Small, because the `sent_post_emails` check walks every row of a post that sent before the blast.
  BATCH_SIZE = 100

  def self.process(dry_run: true, batch_size: BATCH_SIZE)
    new(dry_run:, batch_size:).process
  end

  def initialize(dry_run:, batch_size:)
    @dry_run = dry_run
    @batch_size = batch_size
  end

  def process
    candidate_ids = []
    expired_count = 0
    PostEmailBlast.never_sent
      .where(requested_at: ...AlertOnStalledPostEmailBlastsJob::LOOKBACK.ago)
      .select(:id)
      .find_in_batches(batch_size: @batch_size) do |batch|
        ids = batch.map(&:id)
        unless @dry_run
          ReplicaLagWatcher.watch
          expired_count += PostEmailBlast.expire(ids, reason: PostEmailBlast::EXPIRY_ABANDONED)
        end
        candidate_ids.concat(ids)
      end

    Rails.logger.info("[ExpireAbandonedPostEmailBlasts] dry_run=#{@dry_run} candidates=#{candidate_ids.size} expired=#{expired_count}")
    candidate_ids
  end
end
