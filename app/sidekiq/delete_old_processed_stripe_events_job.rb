# frozen_string_literal: true

class DeleteOldProcessedStripeEventsJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  # Rows only matter within Stripe's webhook redelivery window (automatic retries for ~3 days,
  # manual resends up to 30); exactly-once fulfillment is guaranteed by the finalize service's
  # lock, so anything older is dead weight.
  VALID_DURATION = 30.days
  DELETION_BATCH_SIZE = 100

  def perform
    return unless ProcessedStripeEvent.where("created_at < ?", VALID_DURATION.ago).exists?

    loop do
      ReplicaLagWatcher.watch
      rows = ProcessedStripeEvent.where("created_at < ?", VALID_DURATION.ago).limit(DELETION_BATCH_SIZE)
      break if rows.delete_all.zero?
    end
  end
end
