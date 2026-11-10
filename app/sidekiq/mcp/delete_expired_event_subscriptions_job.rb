# frozen_string_literal: true

class Mcp::DeleteExpiredEventSubscriptionsJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  DELETION_BATCH_SIZE = 1_000

  # Each row holds a client's signing secret. A client that subscribes again later gets the same
  # id, because the id comes from the key.
  def perform
    return unless McpEventSubscription.expired.exists?

    loop do
      ReplicaLagWatcher.watch
      break if McpEventSubscription.expired.limit(DELETION_BATCH_SIZE).delete_all.zero?
    end
  end
end
