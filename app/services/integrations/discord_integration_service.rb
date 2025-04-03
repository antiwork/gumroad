# frozen_string_literal: true

class Integrations::DiscordIntegrationService < Integrations::BaseIntegrationService
  def initialize
    @integration_name = Integration::DISCORD
  end

  def deactivate(purchase)
    super do |integration|
      discord_user_id = DiscordIntegration.discord_user_id_for(purchase)
      if discord_user_id.present?
        begin
          DiscordApi.new.remove_member(integration.server_id, discord_user_id)
          purchase.live_purchase_integrations.find_by(integration:).mark_deleted!
        rescue Discordrb::Errors::NoPermission
          if gumroad_role_higher_than_member_role?(integration.server_id, discord_user_id)
            Bugsnag.notify("Received a Discord permissions error for something other than role position - purchase id #{purchase.id} - server id #{integration.server_id} - discord user id #{discord_user_id}")
            raise
          else
            ContactingCreatorMailer.unremovable_discord_member(discord_user_id, integration.server_name, purchase.id).deliver_later(queue: "critical")
          end
        rescue Discordrb::Errors::UnknownServer => e
          Rails.logger.info("DiscordIntegrationService: Purchase id #{purchase.id} is being deactivated for a deleted Discord server. Discord server id #{integration.server_id} and Discord user id #{discord_user_id}. Proceeding to mark the PurchaseIntegration as deleted. Error: #{e.class} => #{e.message}")
          purchase.live_purchase_integrations.find_by(integration:).mark_deleted!
        end
      end
    end
  end

  private
    def gumroad_role_higher_than_member_role?(discord_server_id, discord_user_id)
      member_role_ids = resolve_member_roles(discord_server_id, discord_user_id)
      return true if member_role_ids.blank?

      gumroad_role_ids = resolve_member_roles(discord_server_id, DISCORD_GUMROAD_BOT_ID)

      roles_response = DiscordApi.new.roles(discord_server_id)
      server_roles = JSON.parse(roles_response.body).sort_by { -_1["position"] }

      member_roles = server_roles.filter { member_role_ids.include?(_1["id"]) }
      gumroad_roles = server_roles.filter { gumroad_role_ids.include?(_1["id"]) }

      highest_member_role_position = member_roles.first&.dig("position") || -1
      highest_gumroad_role_position = gumroad_roles.first&.dig("position") || -1

      highest_gumroad_role_position > highest_member_role_position
    end

    def resolve_member_roles(discord_server_id, discord_user_id)
      resolve_member_response = DiscordApi.new.resolve_member(discord_server_id, discord_user_id)
      member = JSON.parse(resolve_member_response.body)
      member["roles"].uniq
    end
end
