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

  # How long a blast whose audience size is still unknown (it has not finished loading) can hold
  # back a later blast from the same seller. A stuck earlier blast must not block the day.
  UNKNOWN_SIZE_GRACE = 2.hours

  # How soon a blast that yielded to an earlier one still loading looks again.
  EARLIER_BLAST_RECHECK_DELAY = 5.minutes

  MAX_EARLIER_BLASTS_CHECKED = 100

  # The slot goes to the earliest-requested large blast, not to whichever finishes loading its
  # audience first. Called by a blast that is about to claim, before it does.
  #
  # Looks only at blasts the same seller requested earlier today (UTC) that are unfinished,
  # undelivered and have no quota decision yet. Size is read from the audience snapshot the earlier
  # blast already wrote (a Redis list length): no audience is scanned. Returns
  #   :large   an earlier blast with a large snapshot is still waiting for the slot
  #   :loading an earlier blast has no snapshot yet, so its size is unknown; it may still claim
  #   nil      nothing earlier is waiting, the caller may claim
  # Fails closed (:large) when Redis cannot be read.
  def self.earlier_blast_waiting(blast:)
    candidates = PostEmailBlast
      .where(seller_id: blast.seller_id, completed_at: nil, expired_at: nil, first_email_delivered_at: nil)
      .where(requested_at: Time.current.beginning_of_day..)
      .where("requested_at < :at OR (requested_at = :at AND id < :id)", at: blast.requested_at, id: blast.id)
      .order(:requested_at, :id)
      .limit(MAX_EARLIER_BLASTS_CHECKED)
      .pluck(:id, :requested_at)

    waiting = nil
    candidates.each do |id, requested_at|
      next if $redis.exists?(RedisKey.blast_quota_admitted(id))

      size = $redis.llen(RedisKey.blast_audience_snapshot(id))
      return :large if size >= threshold

      waiting = :loading if size.zero? && requested_at > UNKNOWN_SIZE_GRACE.ago
    end
    waiting
  rescue Redis::BaseError, RedisClient::Error => e
    ErrorNotifier.notify(e, seller_id: blast.seller_id)
    :large
  end

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

  # Workflows used to claim the post blast key. A claim made earlier on the deploy day would
  # hold the slot until midnight, so it is taken over. Drop this once that day has passed.
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

  PUBLISH_WARNING_BLASTS_CHECKED = 100

  # What the publish screen shows before a seller confirms a large email. Cheap reads only: one
  # EXISTS on the day's slot key and, when it is free, the seller's blasts requested today (indexed)
  # against the audience snapshots they already wrote (a Redis list length). Never scans an audience.
  #   reason: "used"    today's slot is already claimed
  #           "waiting" an earlier large blast from today has not claimed it yet and will go first
  #           nil       a large email would send right away
  # A Redis error reads as no warning: it is a hint, and the send path still fails closed.
  def self.publish_warning(seller_id:)
    reason = if $redis.exists?(slot_key(seller_id:, kind: "post_blast"))
      "used"
    elsif earlier_large_blast_waiting?(seller_id:)
      "waiting"
    end
    window_start = Time.zone.tomorrow.beginning_of_day + deferral_window_start_seconds

    {
      threshold:,
      reason:,
      date: Date.current.iso8601,
      next_send_window: { starts_at: window_start.utc.iso8601, ends_at: (window_start + deferral_window_length_seconds).utc.iso8601 }
    }
  rescue Redis::BaseError, RedisClient::Error => e
    ErrorNotifier.notify(e, seller_id:)
    { threshold:, reason: nil, date: Date.current.iso8601, next_send_window: nil }
  end

  def self.earlier_large_blast_waiting?(seller_id:)
    ids = PostEmailBlast
      .where(seller_id:, completed_at: nil, expired_at: nil, first_email_delivered_at: nil, requested_at: Time.current.beginning_of_day..)
      .limit(PUBLISH_WARNING_BLASTS_CHECKED).pluck(:id)
    ids.any? do |id|
      !$redis.exists?(RedisKey.blast_quota_admitted(id)) && $redis.llen(RedisKey.blast_audience_snapshot(id)) >= threshold
    end
  end
  private_class_method :earlier_large_blast_waiting?
end
