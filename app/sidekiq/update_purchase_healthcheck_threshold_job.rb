# frozen_string_literal: true

# Keeps the /healthcheck/purchases threshold tracking real traffic instead of a
# hand-set constant. The endpoint compares the last 10 minutes of successful
# purchases against RedisKey.min_successful_purchases_in_last_10_minutes; this
# job sets that key to half the median of the same clock window on the prior 7
# days, so the check pages on a genuine collapse (2026-07-31: -55%) but stays
# quiet through ordinary overnight troughs a static threshold must be sized for.
class UpdatePurchaseHealthcheckThresholdJob
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :critical, lock: :until_executed

  BASELINE_DAYS = 7
  BASELINE_FRACTION = 0.5
  WINDOW = 10.minutes
  # Below this, half-the-median is so small that a single quiet bucket could
  # page; also the fallback when history is empty (fresh environments).
  MIN_THRESHOLD = 100
  # Survives ~6 missed runs, then the endpoint fails closed on the absent key.
  THRESHOLD_TTL = 1.hour

  def perform
    now = Time.current
    baseline_counts = (1..BASELINE_DAYS).map do |days_ago|
      window_end = now - days_ago.days
      successful_count_in((window_end - WINDOW)..window_end)
    end
    median = baseline_counts.sort[BASELINE_DAYS / 2]
    threshold = [(median * BASELINE_FRACTION).round, MIN_THRESHOLD].max

    $redis.set(RedisKey.min_successful_purchases_in_last_10_minutes, threshold, ex: THRESHOLD_TTL.to_i)
  end

  private
    def successful_count_in(range)
      Purchase.successful.where(created_at: range).count
    end
end
