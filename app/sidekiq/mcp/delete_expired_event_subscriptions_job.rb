# frozen_string_literal: true

class Mcp::DeleteExpiredEventSubscriptionsJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  SELLERS_PER_BATCH = 100

  # Each row holds a client's signing secret. A client that subscribes again later gets the same
  # id, because the id comes from the key.
  def perform
    loop do
      user_ids = McpEventSubscription.expired.distinct.limit(SELLERS_PER_BATCH).pluck(:user_id)
      break if user_ids.empty?

      ReplicaLagWatcher.watch
      user_ids.each { |user_id| delete_expired_for(user_id) }
    end
  end

  private
    # Under the lock a subscribe holds, so a renewal that found an expired row keeps it until its
    # update commits. The delete then sees the new lease and leaves the row.
    def delete_expired_for(user_id)
      McpEventSubscription.transaction do
        McpEventSubscription.lock_seller!(user_id)
        McpEventSubscription.expired.where(user_id:).delete_all
      end
    end
end
