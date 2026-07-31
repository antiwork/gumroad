# frozen_string_literal: true

module User::PingNotification
  # An alive resource subscription is not necessarily deliverable: the gate below also needs a live
  # view_sales/account token for the owning application, and a subscription can outlive every token
  # that could satisfy it. Callers that only need URLs use #urls_for_ping_notification; the ping
  # worker needs both halves so it can tell the seller about the ones that will never fire.
  PingNotificationTargets = Struct.new(:post_urls, :deliverable_subscriptions, :undeliverable_subscriptions, keyword_init: true)

  def send_test_ping(url)
    latest_sale = sales.last
    # Distinct sentinel rather than nil: HTTParty::Response overrides #nil? to
    # return true for empty-bodied responses, so callers must never use nil/truthiness
    # checks to distinguish "no sales" from a real response (see TestPingsController).
    return :no_sales if latest_sale.blank?

    URI.parse(url) # TestPingsController.create catches URI::InvalidURIError

    ping_params = latest_sale.payload_for_ping_notification.merge(test: true)
    ping_params = if notification_content_type == Mime[:json]
      ping_params.to_json
    elsif notification_content_type == Mime[:url_encoded_form]
      ping_params.deep_transform_keys { encode_brackets(_1) }
    else
      ping_params
    end

    HTTParty.post(url, body: ping_params, timeout: 5, headers: { "Content-Type" => notification_content_type })
  end

  def urls_for_ping_notification(resource_name)
    ping_notification_targets(resource_name).post_urls
  end

  # Single pass, because resolving deliverability costs a token query per subscription and the read
  # paths (#urls_for_ping_notification, can_ping) run on every sale JSON.
  def ping_notification_targets(resource_name)
    deliverable = []
    undeliverable = []

    resource_subscriptions.alive.where("resource_name = ?", resource_name).find_each do |resource_subscription|
      oauth_application = resource_subscription.oauth_application
      # We had a bug where we were actually deleting the application instead of setting its deleted_at. Handle those gracefully.
      # A revoked application is also a terminal state the seller chose, so it is not undeliverable-and-worth-reporting.
      next if oauth_application.nil? || oauth_application.deleted?

      if resource_subscription.post_url.present? && live_ping_notification_token?(oauth_application)
        deliverable << resource_subscription
      else
        undeliverable << resource_subscription
      end
    end

    post_urls = deliverable.map { [_1.post_url, _1.content_type] }
    post_urls << [notification_endpoint, notification_content_type] if notification_endpoint.present? && resource_name == ResourceSubscription::SALE_RESOURCE_NAME

    PingNotificationTargets.new(post_urls:, deliverable_subscriptions: deliverable, undeliverable_subscriptions: undeliverable)
  end

  private
    def live_ping_notification_token?(oauth_application)
      Doorkeeper::AccessToken.active_for(self).where(application_id: oauth_application.id).any? do |token|
        token.includes_scope?(:view_sales) || token.includes_scope?(:account)
      end
    end

    def encode_brackets(key)
      key.to_s.gsub(/[\[\]]/) { |char| URI.encode_www_form_component(char) }
    end
end
