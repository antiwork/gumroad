# frozen_string_literal: true

class ZoomIntegration < Integration
  INTEGRATION_DETAILS = %w[user_id email access_token refresh_token]
  INTEGRATION_DETAILS.each { |detail| attr_json_data_accessor detail }

  def self.is_enabled_for(purchase)
    purchase.find_enabled_integration(Integration::ZOOM).present?
  end

  def same_connection?(integration)
    integration.type == type && integration.user_id == user_id
  end

  def self.connection_settings
    super + %w[keep_inactive_members]
  end
end
