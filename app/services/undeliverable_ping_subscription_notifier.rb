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

  # Send once and stop, keyed on the advice actually given. The seller cannot re-authorize an app
  # holding no live token, and there is no UI or API to delete the subscription without one, so a
  # repeat is a nag they cannot act on — which is also why these keys carry no expiry.
  #
  # Recorded AFTER delivery, never at enqueue or render. The reason and the decision to send are both
  # render-time state, so claiming at enqueue meant writing a permanent key for advice that might
  # never be sent and then moving it — a write plus a delete, whose failed delete leaves a permanent
  # claim on advice nobody was given. Claiming at render has the same shape one step later: the
  # deliver can still raise, and `deliver_email` itself declines an invalid address, either of which
  # spends the seller's one notice on an email that never went out.
  def self.record_sent(resource_subscription_id, reason)
    return if reason.blank?

    $redis.set(RedisKey.undeliverable_ping_subscription_notified(resource_subscription_id, reason), Time.current.to_i)
  rescue => e
    report(e)
  end

  # Read-only, so a render decides on what has actually been sent. Two renders inside the throttle
  # window can both pass this and send twice; a duplicate is the failure direction this whole notice
  # accepts, unlike the permanent silence a pre-emptive claim causes.
  def self.already_sent?(resource_subscription_id, reason)
    return false if reason.blank?

    $redis.exists?(RedisKey.undeliverable_ping_subscription_notified(resource_subscription_id, reason))
  rescue => e
    report(e)
    false
  end

  def self.report(error)
    ErrorNotifier.notify(error)
  rescue
    nil
  end
  private_class_method :report

  def notify
    return unless resource_subscription.created_at >= SUBSCRIPTION_CLEANUP_CUTOVER
    return unless throttle_enqueue

    begin
      ContactingCreatorMailer.undeliverable_ping_subscription(resource_subscription.id).deliver_later(queue: "low")
    rescue
      # Nothing was enqueued, so the throttle is holding a window against a render that will never
      # happen. Unlike the send-once record this key expires, so a failed release self-heals.
      release_throttle
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

    def release_throttle
      $redis.del(throttle_key)
    rescue => e
      self.class.send(:report, e)
    end

    def throttle_enqueue
      !!$redis.set(throttle_key, Time.current.to_i, nx: true, ex: ENQUEUE_THROTTLE.to_i)
    end
end
