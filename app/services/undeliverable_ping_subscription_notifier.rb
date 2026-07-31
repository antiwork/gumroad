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
    resource_subscriptions.each { new(_1).notify }
  end

  def notify
    return unless resource_subscription.created_at >= SUBSCRIPTION_CLEANUP_CUTOVER
    return unless claim_notification

    ContactingCreatorMailer.undeliverable_ping_subscription(resource_subscription.id, reason).deliver_later(queue: "low")
  end

  private
    attr_reader :resource_subscription

    def reason
      resource_subscription.post_url.present? ? REVOKED_CREDENTIAL : MISSING_POST_URL
    end

    # Send once and stop. The seller cannot re-authorize an app holding no live token, and there is
    # no UI or API to delete the subscription without one, so a repeat is a nag they cannot act on.
    # Unclaimed keys carry no expiry for the same reason.
    def claim_notification
      $redis.set(
        RedisKey.undeliverable_ping_subscription_notified(resource_subscription.id, reason),
        Time.current.to_i,
        nx: true
      )
    end
end
