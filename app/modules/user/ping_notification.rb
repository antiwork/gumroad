# frozen_string_literal: true

module User::PingNotification
  def send_test_ping(url)
    latest_sale = sales.last
    return nil if latest_sale.blank?

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
        token.includes_scope?(:view_sales)
      end
      post_urls << [resource_subscription.post_url, resource_subscription.content_type] if oauth_application && resource_subscription.post_url.present? && can_view_sales
    end
    post_urls << [notification_endpoint, notification_content_type] if notification_endpoint.present? && resource_name == ResourceSubscription::SALE_RESOURCE_NAME
    post_urls
  end

  private
    def encode_brackets(key)
      key.to_s.gsub(/[\[\]]/) { |char| URI.encode_www_form_component(char) }
    end
end
