# frozen_string_literal: true

# One large audience send per seller per day. Five six-figure workflow
# publishes in the same minute is what filled the primary and stalled checkout.
# Workflow sends and post blasts each get their own slot, so a seller's daily workflow
# cannot keep their post blasts from ever sending.
class SellerLargeBlastQuota
  DEFAULT_THRESHOLD = 10_000

  # A post blast still waiting for a slot this long after it was requested ends as not sent:
  # its content is time-boxed, and deferring again only delays a stale email.
  CONTENT_WINDOW = 2.days

  # Measured from UTC midnight because that is when `claim` frees the next day's slot — run
  # a deferred blast earlier and it hits the same claimed key and defers again. 3-7h past it
  # is 23:00-03:00 ET on EDT, 22:00-02:00 ET on EST, both in the traffic trough; the old
  # target of 00:00 UTC exactly was the busiest shopper hour (gumroad-private#2513).
  DEFERRAL_WINDOW_START = 3.hours
  DEFERRAL_WINDOW_LENGTH = 4.hours

  def self.allow?(seller_id:, blast_id:, recipient_count:, kind: "blast")
    return true if recipient_count.to_i < threshold

    claim(seller_id:, claim_id: claim_id_for(kind:, blast_id:), kind:)
  end

  def self.claim(seller_id:, claim_id:, kind: "blast")
    return true if seller_id.blank? || claim_id.blank?

    key = slot_key(seller_id:, kind:)
    return true if $redis.set(key, claim_id, nx: true, ex: ttl_seconds)

    holder = $redis.get(key)
    return true if holder == claim_id

    kind != "workflow" && holder.to_s.start_with?(LEGACY_WORKFLOW_CLAIM_PREFIX) && take_over_legacy_workflow_claim(key:, holder:, claim_id:)
  rescue Redis::BaseError, RedisClient::Error => e
    # Fail closed: admitting every large blast during an outage recreates the stampede.
    ErrorNotifier.notify(e, seller_id:)
    false
  end

  # Before workflow sends had their own slot, they claimed the post blast key. A claim made
  # earlier on the deploy day is still there, and no workflow reads that key any more, so it
  # would hold the post blast slot until midnight. Drop this once that day has passed.
  LEGACY_WORKFLOW_CLAIM_PREFIX = "workflow:"

  TAKE_OVER_SCRIPT = "if redis.call('get', KEYS[1]) == ARGV[1] then redis.call('set', KEYS[1], ARGV[2], 'EX', ARGV[3]) return 1 end return 0"

  def self.take_over_legacy_workflow_claim(key:, holder:, claim_id:)
    $redis.eval(TAKE_OVER_SCRIPT, keys: [key], argv: [holder, claim_id, ttl_seconds]).to_i == 1 ||
      $redis.get(key) == claim_id
  end

  RELEASE_SCRIPT = "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) end return 0"

  # Gives the slot back when the blast that claimed it will not send. Only the holder can
  # release it, so a later claimant's slot is never freed by a stale copy.
  def self.release(seller_id:, blast_id:, kind: "blast")
    claim_id = claim_id_for(kind:, blast_id:)
    return if seller_id.blank? || claim_id.blank?

    $redis.eval(RELEASE_SCRIPT, keys: [slot_key(seller_id:, kind:)], argv: [claim_id])
  rescue Redis::BaseError, RedisClient::Error => e
    ErrorNotifier.notify(e, seller_id:)
  end

  def self.slot_key(seller_id:, kind:)
    if kind == "workflow"
      RedisKey.seller_large_workflow_quota(seller_id, Date.current)
    else
      RedisKey.seller_large_blast_quota(seller_id, Date.current)
    end
  end

  def self.past_content_window?(requested_at:, run_at:)
    requested_at.present? && run_at > requested_at + CONTENT_WINDOW
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
