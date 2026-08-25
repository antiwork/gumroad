# frozen_string_literal: true

# One large audience send per seller per day. Five six-figure workflow
# publishes in the same minute is what filled the primary and stalled checkout.
class SellerLargeBlastQuota
  DEFAULT_THRESHOLD = 10_000

  def self.allow?(seller_id:, blast_id:, recipient_count:)
    return true if recipient_count.to_i < threshold

    claim(seller_id:, blast_id:)
  end

  def self.claim(seller_id:, blast_id:)
    return true if seller_id.blank? || blast_id.blank?

    key = RedisKey.seller_large_blast_quota(seller_id, Date.current)
    return true if $redis.set(key, blast_id.to_s, nx: true, ex: ttl_seconds)

    $redis.get(key) == blast_id.to_s
  rescue Redis::BaseError, RedisClient::Error => e
    ErrorNotifier.notify(e, seller_id:)
    true
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
