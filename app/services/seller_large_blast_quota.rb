# frozen_string_literal: true

# One large audience send per seller per day. Five six-figure workflow
# publishes in the same minute is what filled the primary and stalled checkout.
class SellerLargeBlastQuota
  DEFAULT_THRESHOLD = 10_000

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
    ErrorNotifier.notify(e, seller_id:)
    true
  end

  def self.claim_id_for(kind:, blast_id:)
    return if blast_id.blank?

    "#{kind}:#{blast_id}"
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
