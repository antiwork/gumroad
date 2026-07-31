# frozen_string_literal: true

# Tells a seller when one of their alive resource subscriptions cannot deliver, because nothing else
# will: PostToPingEndpointsWorker returns early on an empty URL list, so there is no POST, no retry,
# and no failure the seller can see, while the subscription keeps reading as active in the API.
class UndeliverablePingSubscriptionNotifier
  # OauthApplication#revoke_access_for and #mark_deleted! soft-delete a seller's subscriptions, so a
  # disconnect since then cannot leave one alive and token-less. Before it, every disconnect did:
  # 829 of the 864 currently-undeliverable subscriptions are pre-cutover Printful/Kit/Zapier/Drip
  # disconnects whose owners would be told to re-authorize an app they deliberately removed. A
  # subscription created after the cutover is broken, not abandoned, which is what this notifies on.
  SUBSCRIPTION_CLEANUP_CUTOVER = Time.utc(2026, 7, 6)

  MISSING_POST_URL = "missing_post_url"
  REVOKED_CREDENTIAL = "revoked_credential"

  # Only wide enough to keep a busy seller's sales from enqueuing one render per sale. It must expire,
  # and it must not be read as evidence the seller was told: whether the email is owed is decided at
  # render, so a lost or kept key here can only cost a no-op job, never a notice.
  ENQUEUE_THROTTLE = 1.hour

  # How long a claim stays provisional. Two renders can overlap — the enqueue throttle is keyed on the
  # reason at enqueue and both jobs resolve the reason again at render — so the decision to send has
  # to be exclusive, not a read. It only has to cover handing one message to the delivery method, and
  # expiring is the backstop for a render that dies before it can say the send did not happen.
  SEND_CLAIM_TTL = 10.minutes

  # Settle only what this render holds. A claim expires, so the key may already carry a successor's
  # token or the permanent record of a send that successor completed; overwriting either would let a
  # later release discard a real send, or a later event repeat one. An absent key is settled too — an
  # expiry nobody claimed behind is still this render's send to record.
  SETTLE_IF_HELD = <<~LUA
    local current = redis.call('GET', KEYS[1])
    if current == false or current == ARGV[1] then
      return redis.call('SET', KEYS[1], ARGV[2])
    end
    return nil
  LUA

  # Release only what this render holds, and never an absent key: absent means the claim expired and
  # a DEL would be a no-op anyway, while a different value means a successor's claim or a completed
  # send that must survive.
  RELEASE_IF_HELD = <<~LUA
    if redis.call('GET', KEYS[1]) == ARGV[1] then
      return redis.call('DEL', KEYS[1])
    end
    return 0
  LUA

  def initialize(resource_subscription)
    @resource_subscription = resource_subscription
  end

  def self.notify_all(resource_subscriptions)
    resource_subscriptions.each do |resource_subscription|
      new(resource_subscription).notify
    rescue => e
      # A seller can have several broken subscriptions, and the events that reach here are one-shot
      # (subscription_ended, dispute_won): there is no later event to retry the ones we skipped, so
      # a Redis or enqueue failure on the first must not cost the rest their only notice.
      report(e)
    end
  end

  def self.reason_for(resource_subscription)
    resource_subscription.post_url.present? ? REVOKED_CREDENTIAL : MISSING_POST_URL
  end

  # Written into the key once a message has actually been transmitted, in place of the claiming
  # render's token. Distinguishable from a token on purpose: settling and releasing both have to tell
  # "the claim I took is still here" from "someone else's claim, or a send that already happened".
  SENT = "sent"

  # Send once and stop, keyed on the advice actually given. The seller cannot re-authorize an app
  # holding no live token, and there is no UI or API to delete the subscription without one, so a
  # repeat is a nag they cannot act on — which is also why the record carries no expiry.
  #
  # This makes the render's claim permanent; it does not create it. Writing the key here for the first
  # time would leave the gap between deciding to send and recording it, which two overlapping renders
  # both fit through. Called AFTER delivery, because a claim that expires costs at worst a repeat while
  # a permanent record written for a message that never left costs the notice itself.
  #
  # Conditional on still holding the claim, because a claim expires: a render whose token is gone has
  # been replaced, and rewriting the key would put a permanent record under a successor's provisional
  # claim — which that successor then releases on a failed delivery, discarding a send that did happen.
  # Absent is claimed too, so an expiry with nobody behind it still records the send.
  def self.record_sent(resource_subscription_id, reason, token)
    return if reason.blank? || token.blank?

    $redis.eval(
      SETTLE_IF_HELD,
      keys: [RedisKey.undeliverable_ping_subscription_notified(resource_subscription_id, reason)],
      argv: [token, SENT]
    )
  rescue => e
    report(e)
  end

  # Takes the notice and returns the token proving this render holds it, or nil when someone else does.
  # This is the render's decision to send, so it has to be one write rather than a read followed by
  # one: overlapping renders both reading an absent record would both send. The claim is provisional
  # until `record_sent` makes it permanent — a claim is not evidence the seller was told, which is why
  # it expires and why the send path gives it back the moment it knows nothing went out.
  #
  # An unusable store sends. Silence is the failure this notice exists to break, and the cost of the
  # other direction is a possible repeat.
  def self.claim_send(resource_subscription_id, reason)
    return nil if reason.blank?

    token = SecureRandom.hex(16)
    claimed = $redis.set(
      RedisKey.undeliverable_ping_subscription_notified(resource_subscription_id, reason),
      token, nx: true, ex: SEND_CLAIM_TTL.to_i
    )
    claimed ? token : nil
  rescue => e
    report(e)
    token
  end

  # Gives back a claim this render took and did not spend, and only that claim. Deleting the key
  # unconditionally would let a render whose claim has already expired delete what replaced it: a
  # successor's live claim, or the permanent record of a send that successor completed — and then the
  # next event claims a free key and emails the seller a second time.
  def self.release_claim(resource_subscription_id, reason, token)
    return if reason.blank? || token.blank?

    $redis.eval(
      RELEASE_IF_HELD,
      keys: [RedisKey.undeliverable_ping_subscription_notified(resource_subscription_id, reason)],
      argv: [token]
    )
  rescue => e
    report(e)
  end

  def self.report(error)
    ErrorNotifier.notify(error)
  rescue
    nil
  end
  private_class_method :report

  def notify
    return unless resource_subscription.created_at >= SUBSCRIPTION_CLEANUP_CUTOVER

    key = throttle_key
    return unless claim_throttle(key)

    begin
      ContactingCreatorMailer.undeliverable_ping_subscription(resource_subscription.id).deliver_later(queue: "low")
    rescue
      # Nothing was enqueued, so the throttle is holding a window against a render that will never
      # happen. Release the key we took, not a freshly derived one: the subscription can change under
      # us, and re-deriving would free a window nobody holds while keeping the one we do. Unlike the
      # send-once record this key expires, so even a failed release self-heals.
      release_throttle(key)
      raise
    end
  end

  private
    attr_reader :resource_subscription

    def throttle_key
      RedisKey.undeliverable_ping_subscription_enqueued(
        resource_subscription.id, self.class.reason_for(resource_subscription)
      )
    end

    def release_throttle(key)
      $redis.del(key)
    rescue => e
      self.class.send(:report, e)
    end

    def claim_throttle(key)
      !!$redis.set(key, Time.current.to_i, nx: true, ex: ENQUEUE_THROTTLE.to_i)
    end
end
