# frozen_string_literal: true

class GoogleCalendarIntegration < Integration
  INTEGRATION_DETAILS = %w[access_token refresh_token calendar_id calendar_summary email]
  INTEGRATION_DETAILS.each { |detail| attr_json_data_accessor detail }

  def self.is_enabled_for(purchase)
    purchase.find_enabled_integration(Integration::GOOGLE_CALENDAR).present?
  end

  def same_connection?(integration)
    integration.type == type && integration.email == email
  end

  def disconnect!
    response = GoogleCalendarApi.new.disconnect(access_token)
    response.code == 200 || response.body.include?("invalid_token") || response.body.include?("Token is not revocable")
  rescue RestClient::NotFound
    false
  end

  def self.connection_settings
    super + %w[keep_inactive_members]
  end
end
