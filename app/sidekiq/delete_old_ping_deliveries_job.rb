# frozen_string_literal: true

class DeleteOldPingDeliveriesJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  # Rows answer "did the ping for this sale go out?" in support tickets, which arrive within weeks
  # of the sale; the readers only ever show the newest few per seller.
  VALID_DURATION = 90.days
  DELETION_BATCH_SIZE = 1_000

  def perform
    return unless PingDelivery.where("created_at < ?", VALID_DURATION.ago).exists?

    loop do
      ReplicaLagWatcher.watch
      rows = PingDelivery.where("created_at < ?", VALID_DURATION.ago).limit(DELETION_BATCH_SIZE)
      break if rows.delete_all.zero?
    end
  end
end
