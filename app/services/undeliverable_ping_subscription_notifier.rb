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

  # The claim is taken at enqueue, but the mailer suppresses the send when the subscription is
  # deliverable again by render time. Holding the claim then spends the seller's one notice on an
  # email nobody received, and the same reason breaking a second time would go unreported.
  def self.release_claim(resource_subscription_id, reason)
    return if reason.blank?

    $redis.del(RedisKey.undeliverable_ping_subscription_notified(resource_subscription_id, reason))
  rescue => e
    report(e)
  end

  # The advice is chosen at render time, so the send-once claim has to be the one for the advice
  # actually given. Keyed on the enqueued reason instead, the two drift whenever the subscription
  # changes in the window: a seller told to fill in a URL does so, the revoked token still blocks
  # delivery, and the notice they are owed is refused by a claim taken under a reason they were
  # never told about. Returns false when that advice has already been sent once.
  def self.reconcile_claim(resource_subscription_id, claimed:, rendered:)
    return true if claimed == rendered

    claimed_rendered = claim(resource_subscription_id, rendered)
    release_claim(resource_subscription_id, claimed)
    claimed_rendered
  rescue => e
    report(e)
    # Sending on a bookkeeping failure beats withholding: the claim is wrong either way, and silence
    # is the thing this notice exists to break.
    true
  end

  def self.claim(resource_subscription_id, reason)
    !!$redis.set(
      RedisKey.undeliverable_ping_subscription_notified(resource_subscription_id, reason),
      Time.current.to_i,
      nx: true
    )
  end

  def self.report(error)
    ErrorNotifier.notify(error)
  rescue
    nil
  end
  private_class_method :report

  def notify
    return unless resource_subscription.created_at >= SUBSCRIPTION_CLEANUP_CUTOVER
    return unless claim_notification

    ContactingCreatorMailer.undeliverable_ping_subscription(resource_subscription.id, reason).deliver_later(queue: "low")
  end

  private
    attr_reader :resource_subscription

    def reason
      self.class.reason_for(resource_subscription)
    end

    # Send once and stop. The seller cannot re-authorize an app holding no live token, and there is
    # no UI or API to delete the subscription without one, so a repeat is a nag they cannot act on.
    # Keys carry no expiry for the same reason; the mailer releases one when it suppresses the send.
    def claim_notification
      self.class.claim(resource_subscription.id, reason)
    end
end
