# frozen_string_literal: true

module HelperWidget
  extend ActiveSupport::Concern

  included do
    helper_method :show_helper_widget?, :helper_widget_host, :helper_widget_init_data
  end

  class_methods do
    def allow_anonymous_access_to_helper_widget(options = {})
      before_action :allow_anonymous_access_to_helper_widget, options
    end
  end

  def helper_widget_host
    ENV.fetch("HELPER_WIDGET_HOST", "https://help.gumroad.com")
  end

  def show_helper_widget?
    return false if Rails.env.test?
    return false if request.host != DOMAIN

    current_seller.present? || allow_anonymous_access_to_helper_widget?
  end

  def allow_anonymous_access_to_helper_widget
    @allow_anonymous_access_to_helper_widget = true
  end

  def allow_anonymous_access_to_helper_widget?
    anonymous_helper_widget_access_enabled? && !!@allow_anonymous_access_to_helper_widget
  end

  def anonymous_helper_widget_access_enabled?
    Feature.active?(:anonymous_helper_widget_access) || params[:anonymous_helper_widget_access].present?
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

  def helper_widget_init_data
    timestamp = (Time.current.to_f * 1000).to_i

    data = {
      title: "Support",
      mailboxSlug: "gumroad",
      iconColor: "#FF90E8",
      enableGuide: true,
      timestamp: timestamp,
    }

    if current_seller.present?
      data[:email] = current_seller.email
      data[:emailHash] = helper_widget_email_hmac(timestamp)
      data[:customerMetadata] = helper_customer_metadata
    end

    data
  end
end
