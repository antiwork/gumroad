# frozen_string_literal: true

class PostToPingEndpointsWorker
  include Sidekiq::Job
  sidekiq_options retry: 20, queue: :critical

  class UnresolvedPingEndpoint < StandardError; end

  def perform(purchase_id, url_parameters, resource_name = ResourceSubscription::SALE_RESOURCE_NAME, subscription_id = nil, additional_params = {})
    ActiveRecord::Base.connection.stick_to_primary!

    if subscription_id.present?
      subscription = Subscription.find(subscription_id)
      return if resource_name == ResourceSubscription::SUBSCRIPTION_ENDED_RESOURCE_NAME && subscription.deactivated_at.blank?
      return if resource_name == ResourceSubscription::SUBSCRIPTION_RESTARTED_RESOURCE_NAME && subscription.termination_date.present?
      user = subscription.link.user
      ping_params = subscription.payload_for_ping_notification(resource_name:, additional_params:)
    else
      purchase = Purchase.find(purchase_id)
      user = purchase.seller
      ping_params = purchase.payload_for_ping_notification(url_parameters:, resource_name:)
    end

    targets = user.ping_notification_targets(resource_name)
    # Notified from the delivery path only. urls_for_ping_notification also backs the can_ping flag
    # on every sale JSON render, and a read has no business emailing anyone.
    notify_undeliverable_subscriptions(targets.undeliverable_subscriptions)

    post_urls = targets.post_urls
    return if post_urls.empty?

    posted = 0
    unresolved = 0
    post_urls.each do |post_url, content_type|
      status = ResourceSubscription.post_url_delivery_status(post_url)
      case status
      when :ok
        PostToIndividualPingEndpointWorker.perform_async(post_url, ping_params.deep_stringify_keys, content_type, user.id)
        posted += 1
      when :unresolved
        unresolved += 1
        Rails.logger.info("PostToPingEndpointsWorker unresolved DNS host=#{ping_url_host(post_url)} user_id=#{user.id}")
      else
        Rails.logger.info("PostToPingEndpointsWorker skipped post_url status=#{status} host=#{ping_url_host(post_url)} user_id=#{user.id}")
      end
    end

    # Raise only when nothing posted, so a sibling public URL is not re-sent on retry.
    raise UnresolvedPingEndpoint, "user_id=#{user.id} unresolved=#{unresolved}" if posted.zero? && unresolved.positive?
  end

  private
    def ping_url_host(post_url)
      URI.parse(post_url).hostname
    rescue URI::InvalidURIError
      "unparseable"
    end

    # This queue is :critical, so nothing in here may reach the caller: a notifier failure must not
    # hold up the webhooks that DO work, and neither may a Sentry client that is itself down.
    def notify_undeliverable_subscriptions(subscriptions)
      UndeliverablePingSubscriptionNotifier.notify_all(subscriptions)
    rescue => e
      begin
        ErrorNotifier.notify(e)
      rescue
        nil
      end
    end
end
