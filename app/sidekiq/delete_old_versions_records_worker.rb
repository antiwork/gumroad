# frozen_string_literal: true

class DeleteOldVersionsRecordsWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  MAX_ALLOWED_ROWS = 100_000_000
  DELETION_BATCH_SIZE = 100

  # Counting rows is not free, so we're relying on the fact that ids are consecutive instead.
  def perform
    max_id = PaperTrail::Version.maximum(:id)
    return if max_id.nil?

    minimum_id_to_keep = max_id - MAX_ALLOWED_ROWS
    loop do
      ReplicaLagWatcher.watch
      rows = PaperTrail::Version.where("id <= ?", minimum_id_to_keep).limit(DELETION_BATCH_SIZE)
      break if rows.delete_all.zero?
    end
  end
end
