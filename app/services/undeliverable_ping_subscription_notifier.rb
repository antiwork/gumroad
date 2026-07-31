# frozen_string_literal: true

# Tells a seller when one of their alive resource subscriptions cannot deliver, because nothing else
# will: PostToPingEndpointsWorker returns early on an empty URL list, so there is no POST, no retry,
# and no failure the seller can see, while the subscription keeps reading as active in the API.
#
# Deduplicated on (subscription, reason) for NOTIFICATION_INTERVAL. A misconfiguration is usually
# permanent, and this runs once per sale, so without the claim a busy seller gets an email per sale.
class UndeliverablePingSubscriptionNotifier
  NOTIFICATION_INTERVAL = 7.days

  MISSING_POST_URL = "missing_post_url"
  REVOKED_CREDENTIAL = "revoked_credential"

  def initialize(resource_subscription)
    @resource_subscription = resource_subscription
  end

  def self.notify_all(resource_subscriptions)
    resource_subscriptions.each { new(_1).notify }
  end

  def notify
    return unless claim_notification

    ContactingCreatorMailer.undeliverable_ping_subscription(resource_subscription.id, reason).deliver_later(queue: "low")
  end

  private
    attr_reader :resource_subscription

    def reason
      resource_subscription.post_url.present? ? REVOKED_CREDENTIAL : MISSING_POST_URL
    end

    # SET NX is the claim: whichever sale gets here first sends, the rest no-op until it expires.
    # Claiming before the enqueue means a failure to enqueue costs one silent interval rather than
    # a mail storm, which is the safer direction for a notice the seller can also read in settings.
    def claim_notification
      $redis.set(
        RedisKey.undeliverable_ping_subscription_notified(resource_subscription.id, reason),
        Time.current.to_i,
        ex: NOTIFICATION_INTERVAL.to_i,
        nx: true
      )
    end
end
