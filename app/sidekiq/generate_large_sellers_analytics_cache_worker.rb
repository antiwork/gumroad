# frozen_string_literal: true

class GenerateLargeSellersAnalyticsCacheWorker
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :low, lock: :until_executed
  include RecurringLockTtl
  # Tightest headroom in the fleet: a queue delay over 15 min can let the next hourly enqueue
  # overlap a still-running attempt. Safe because regeneration is idempotent — concurrent copies
  # recompute the same dates to the same values, costing duplicated work rather than wrong data.
  recurring_lock_ttl max_attempt: 45.minutes

  def perform
    User.joins(:large_seller).find_each do |user|
      CreatorAnalytics::CachingProxy.new(user).generate_cache
    rescue => e
      ErrorNotifier.notify(e) do |report|
        report.add_tab(:user_info, id: user.id)
      end
    end
  end
end
