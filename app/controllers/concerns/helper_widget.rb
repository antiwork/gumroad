# frozen_string_literal: true

module HelperWidget
  extend ActiveSupport::Concern

  included do
    helper_method :show_helper_widget?, :helper_widget_host, :helper_widget_email_hmac, :helper_customer_metadata, :enable_helper_guide?
  end

  def helper_widget_host
    ENV.fetch("HELPER_WIDGET_HOST", "https://helper.ai")
  end

  def show_helper_widget?
    return false if Rails.env.test?
    return false unless request.host == DOMAIN
    # Always show helper widget on marketing pages
    return true if controller_name == "home" && %w[about features pricing terms prohibited privacy taxes].include?(action_name)

    current_seller && Feature.active?(:helper_widget, current_seller)
  end

  def enable_helper_guide?
    Feature.active?(:helper_guide)
  end

  def helper_customer_metadata
    Rails.cache.fetch("helper_customer_metadata/#{current_seller.id}", expires_in: 1.hour) do
      HelperUserInfoService.new(email: current_seller.email).metadata
    end
  end

  def helper_widget_email_hmac(timestamp)
    message = "#{current_seller.email}:#{timestamp}"

    OpenSSL::HMAC.hexdigest(
      "sha256",
      GlobalConfig.get("HELPER_WIDGET_SECRET"),
      message
    )
  end
end
