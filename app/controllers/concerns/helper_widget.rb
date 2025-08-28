# frozen_string_literal: true

module HelperWidget
  extend ActiveSupport::Concern

  included do
    helper_method :helper_widget_host, :helper_session
  end

  def helper_widget_host
    GlobalConfig.get("HELPER_WIDGET_HOST")
  end

  def helper_session
    return unless current_seller

    timestamp = (Time.current.to_f * 1000).to_i

    {
      email: current_seller.email,
      emailHash: helper_widget_email_hmac(timestamp),
      timestamp:,
      customerMetadata: helper_customer_metadata,
    }
  end

  private
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
