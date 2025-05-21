# frozen_string_literal: true

class Integrations::DiscordController < ApplicationController
  before_action :authenticate_user!, except: [:oauth_redirect, :join_server, :leave_server]

  def server_info
    discord_api = DiscordApi.new
    oauth_response = discord_api.oauth_token(params[:code], oauth_redirect_integrations_discord_index_url)
    server = oauth_response.parsed_response&.dig("guild")
    access_token = oauth_response.parsed_response&.dig("access_token")
    return render json: { success: false } unless oauth_response.success? && server.present? && access_token.present?

    begin
      user_response = discord_api.identify(access_token)

      user = JSON.parse(user_response)
      render json: { success: true, server_id: server["id"], server_name: server["name"], username: user["username"] }
    rescue Discordrb::Errors::CodeError
      render json: { success: false }
    end
  end

  def join_server
    return render json: { success: false } if params[:code].blank? || params[:purchase_id].blank?

    discord_api = DiscordApi.new
    oauth_response = discord_api.oauth_token(params[:code], oauth_redirect_integrations_discord_index_url(host: DOMAIN, protocol: PROTOCOL))
    access_token = oauth_response.parsed_response&.dig("access_token")

    return render json: { success: false } unless oauth_response.success? && access_token.present?

    begin
      user_response = discord_api.identify(access_token)
      user = JSON.parse(user_response)

      purchase = Purchase.find_by_external_id(params[:purchase_id])
      integration = purchase.find_enabled_integration(Integration::DISCORD)
      return render json: { success: false } if integration.nil?

      add_member_response = discord_api.add_member(integration.server_id, user["id"], access_token)
      return render json: { success: false } unless add_member_response.code === 201 || add_member_response.code === 204

      purchase_integration = purchase.purchase_integrations.build(integration:, discord_user_id: user["id"])
      if purchase_integration.save
        render json: { success: true, server_name: integration.server_name }
      else
        render json: { success: false }
      end
    rescue Discordrb::Errors::CodeError, Discordrb::Errors::NoPermission
      render json: { success: false }
    end
  end

  def leave_server
    return render json: { success: false } if params[:purchase_id].blank?

    purchase = Purchase.find_by_external_id(params[:purchase_id])
    integration = purchase.find_integration_by_name(Integration::DISCORD)
    discord_user_id = DiscordIntegration.discord_user_id_for(purchase)
    return render json: { success: false } if integration.nil? || discord_user_id.blank?

    begin
      response = DiscordApi.new.remove_member(integration.server_id, discord_user_id)
      return render json: { success: false } unless response.code === 204
    rescue Discordrb::Errors::UnknownServer => e
      Rails.logger.info("DiscordController: Customer with purchase ID #{purchase.id} is trying to leave a deleted Discord server. Proceeding to mark the PurchaseIntegration as deleted. Error: #{e.class} => #{e.message}")
    rescue Discordrb::Errors::NoPermission
      return render json: { success: false }
    end

    purchase.live_purchase_integrations.find_by(integration:).mark_deleted!
    render json: { success: true, server_name: integration.server_name }
  end

  def oauth_redirect
    if params[:state].present?
      state = JSON.parse(params[:state])

      is_admin = state.dig("is_admin") == true
      encrypted_product_id = state.dig("product_id")
      if is_admin && !encrypted_product_id.nil?
        decrypted_product_id = ObfuscateIds.decrypt(CGI.unescape(encrypted_product_id))
        redirect_to join_discord_admin_link_path(decrypted_product_id, code: params[:code])
        return
      end

      seller = User.find(ObfuscateIds.decrypt(CGI.unescape(state.dig("seller_id"))))
      if seller.present?
        host = state.dig("is_custom_domain") ? seller.custom_domain.domain : seller.subdomain
        redirect_to oauth_redirect_integrations_discord_index_url(host:, params: { code: params[:code] }),
                    allow_other_host: true
        return
      end
    end

    render inline: "", layout: "application", status: params.key?(:code) ? :ok : :bad_request
  end
end
