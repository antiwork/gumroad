# frozen_string_literal: true

module User::PingNotification
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
    post_urls = []
    resource_subscriptions.alive.where("resource_name = ?", resource_name).find_each do |resource_subscription|
      oauth_application = resource_subscription.oauth_application
      # We had a bug where we were actually deleting the application instead of setting its deleted_at. Handle those gracefully.
      next if oauth_application.nil? || oauth_application.deleted?

      can_view_sales = Doorkeeper::AccessToken.active_for(self).where(application_id: oauth_application.id).find do |token|
        token.includes_scope?(:view_sales) || token.includes_scope?(:account)
      end
      if resource_subscription.post_url.present? && can_view_sales
        post_urls << [resource_subscription.post_url, resource_subscription.content_type]
      else
        report_undeliverable(resource_subscription, resource_name, can_view_sales:)
      end
    end
    post_urls << [notification_endpoint, notification_content_type] if notification_endpoint.present? && resource_name == ResourceSubscription::SALE_RESOURCE_NAME
    post_urls
  end

  private
    # A live resource subscription that produces no post URL delivers nothing, forever, with no
    # trace on either side: PostToPingEndpointsWorker returns early on an empty list, so there is
    # no attempt to retry and no failure for the seller to see. The subscription keeps reading as
    # active in the API. Report it so the silence is visible while the delivery contract for
    # agent-created subscriptions is decided (gumroad-private#1545).
    def report_undeliverable(resource_subscription, resource_name, can_view_sales:)
      ErrorNotifier.notify(
        "Resource subscription is undeliverable: no post URL resolved for an alive subscription",
        resource_subscription_id: resource_subscription.id,
        resource_name:,
        seller_id: id,
        oauth_application_id: resource_subscription.oauth_application_id,
        post_url_present: resource_subscription.post_url.present?,
        live_view_sales_token: can_view_sales.present?
      )
    end

    def encode_brackets(key)
      key.to_s.gsub(/[\[\]]/) { |char| URI.encode_www_form_component(char) }
    end
end
