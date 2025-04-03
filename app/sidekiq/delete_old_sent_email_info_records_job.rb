# frozen_string_literal: true

class DeleteOldSentEmailInfoRecordsJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  VALID_DURATION = 1.year
  DELETION_BATCH_SIZE = 100

  def perform
    return unless SentEmailInfo.exists?

    loop do
      ReplicaLagWatcher.watch
      rows = SentEmailInfo.where("created_at < ?", VALID_DURATION.ago).limit(DELETION_BATCH_SIZE)
      break if rows.delete_all.zero?
    end
  end
end
