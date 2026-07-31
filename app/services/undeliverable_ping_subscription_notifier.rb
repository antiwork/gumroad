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
  # repeat is a nag they cannot act on — which is also why this key carries no expiry.
  #
  # The mailer takes it, not the enqueue path, and that placement is the whole safety property: the
  # reason and the decision to send at all are both render-time state, so claiming earlier meant
  # writing a permanent key for advice that might never be sent and then moving it afterwards. A move
  # is a write plus a delete, and a delete that fails leaves a permanent claim on a reason the seller
  # was never told, silently refusing the notice owed when that reason breaks. Claimed here it is one
  # atomic SET NX with nothing to undo.
  def self.claim(resource_subscription_id, reason)
    return false if reason.blank?

    !!$redis.set(
      RedisKey.undeliverable_ping_subscription_notified(resource_subscription_id, reason),
      Time.current.to_i,
      nx: true
    )
  rescue => e
    report(e)
    # Sending on a bookkeeping failure beats withholding: silence is the thing this notice exists to
    # break, and the cost of getting it wrong is one repeat email rather than a permanent gap.
    true
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

    ContactingCreatorMailer.undeliverable_ping_subscription(resource_subscription.id).deliver_later(queue: "low")
  end

  private
    attr_reader :resource_subscription

    def throttle_enqueue
      !!$redis.set(
        RedisKey.undeliverable_ping_subscription_enqueued(resource_subscription.id, self.class.reason_for(resource_subscription)),
        Time.current.to_i,
        nx: true,
        ex: ENQUEUE_THROTTLE.to_i
      )
    end
end
