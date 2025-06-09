# frozen_string_literal: true

class LargeSellersUpdateUserBalanceStatsCacheWorker
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :low

  MINUTES_BETWEEN_JOBS = 1

  def perform
    minutes_between_jobs = ($redis.get(RedisKey.balance_stats_scheduler_minutes_between_jobs) || MINUTES_BETWEEN_JOBS).to_i
    user_ids = UserBalanceStatsService.cacheable_users.pluck(:id)
    user_ids.each.with_index do |user_id, i|
      UpdateUserBalanceStatsCacheWorker.perform_in(i * minutes_between_jobs.minutes, user_id)
    end
  end
end
