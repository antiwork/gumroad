# frozen_string_literal: true

class DiscordIntegration < Integration
  INTEGRATION_DETAILS = %w[username server_id server_name]
  INTEGRATION_DETAILS.each { |detail| attr_json_data_accessor detail }

  def self.discord_user_id_for(purchase)
    integration = purchase.find_enabled_integration(Integration::DISCORD)
    return nil unless integration.present?

    purchase.live_purchase_integrations.find_by(integration:).try(:discord_user_id)
  end

  def self.is_enabled_for(purchase)
    purchase.find_enabled_integration(Integration::DISCORD).present?
  end

  def disconnect!
    response = DiscordApi.new.disconnect(server_id)
    response.code == 204
  rescue Discordrb::Errors::UnknownServer => e
    Rails.logger.info("DiscordIntegration: Attempting to disconnect from a deleted Discord server. Proceeding as a successful disconnection. DiscordIntegration ID #{self.id}. Error: #{e.class} => #{e.message}")
    true
  rescue Discordrb::Errors::CodeError
    false
  end

  def same_connection?(integration)
    integration.type == type && integration.try(:server_id) == server_id
  end

  def self.connection_settings
    super + %w[keep_inactive_members]
  end
end
