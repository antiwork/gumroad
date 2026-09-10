# frozen_string_literal: true

# One large audience send per seller per day. Five six-figure workflow
# publishes in the same minute is what filled the primary and stalled checkout.
class SellerLargeBlastQuota
  DEFAULT_THRESHOLD = 10_000

  # Measured from UTC midnight because that is when `claim` frees the next day's slot — run
  # a deferred blast earlier and it hits the same claimed key and defers again. 3-7h past it
  # is 23:00-03:00 ET on EDT, 22:00-02:00 ET on EST, both in the traffic trough; the old
  # target of 00:00 UTC exactly was the busiest shopper hour (gumroad-private#2513).
  DEFERRAL_WINDOW_START = 3.hours
  DEFERRAL_WINDOW_LENGTH = 4.hours

  def self.allow?(seller_id:, blast_id:, recipient_count:, kind: "blast")
    return true if recipient_count.to_i < threshold

    claim(seller_id:, claim_id: claim_id_for(kind:, blast_id:))
  end

  def self.claim(seller_id:, claim_id:)
    return true if seller_id.blank? || claim_id.blank?

    key = RedisKey.seller_large_blast_quota(seller_id, Date.current)
    return true if $redis.set(key, claim_id, nx: true, ex: ttl_seconds)

    $redis.get(key) == claim_id
  rescue Redis::BaseError, RedisClient::Error => e
    # Fail closed: admitting every large blast during an outage recreates the stampede.
    ErrorNotifier.notify(e, seller_id:)
    false
  end

  def self.claim_id_for(kind:, blast_id:)
    return if blast_id.blank?

    "#{kind}:#{blast_id}"
  end

  # Each caller draws independently — that, not any coordination, is what spreads the herd.
  def self.deferred_run_at
    Time.zone.tomorrow.beginning_of_day + deferral_window_start_seconds + rand(deferral_window_length_seconds)
  end

  def self.deferral_window_start_seconds
    tunable_seconds(RedisKey.seller_large_blast_deferral_window_start_seconds, DEFERRAL_WINDOW_START, minimum: 0)
  end

  def self.deferral_window_length_seconds
    tunable_seconds(RedisKey.seller_large_blast_deferral_window_length_seconds, DEFERRAL_WINDOW_LENGTH, minimum: 1)
  end

  def self.tunable_seconds(key, default, minimum:)
    raw = $redis.get(key)
    return default.to_i if raw.blank?

    value = raw.to_i
    value >= minimum ? value : default.to_i
  rescue Redis::BaseError, RedisClient::Error
    default.to_i
  end

  def self.threshold
    value = ($redis.get(RedisKey.seller_large_blast_threshold) || DEFAULT_THRESHOLD).to_i
    value.positive? ? value : DEFAULT_THRESHOLD
  rescue Redis::BaseError, RedisClient::Error
    DEFAULT_THRESHOLD
  end

  def self.ttl_seconds
    [(Time.zone.now.end_of_day - Time.zone.now).to_i, 60].max
  end
end
