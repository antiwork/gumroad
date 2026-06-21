# frozen_string_literal: true

class BackfillAudienceMembersIndexJob
  include Sidekiq::Job
  sidekiq_options queue: :mongo, retry: 5, lock: :until_executed

  # Activating the flag makes all future jobs no-op (an emergency stop for an
  # in-flight spread). Skipped ranges are consumed, not deferred: to resume,
  # deactivate the flag, clear the backfill cursor, and re-run spread — every
  # write is an idempotent full-document overwrite, so re-covering is harmless.
  def perform(start_id, end_id, seller_id = nil, batch_size = Onetime::BackfillAudienceMembersIndex::BATCH_SIZE)
    return unless Feature.inactive?(:pause_audience_members_index_backfill)

    Onetime::BackfillAudienceMembersIndex.new(batch_size:, seller_id:).index_range(start_id, end_id)
  end
end
