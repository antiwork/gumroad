# frozen_string_literal: true

class Integrations::DiscordController < ApplicationController
  # join_server and leave_server gate on the signed-in purchaser OR possession of
  # the purchase's download token: the external id alone is public (echoed on product
  # reviews), so it must not grant Discord membership control. The token is the same
  # per-purchase secret the download page is gated on, so guest purchasers with an
  # account-free checkout still work.
  before_action :authenticate_user!, except: [:oauth_redirect, :join_server, :leave_server]

  def server_info
    discord_api = DiscordApi.new
    oauth_response = discord_api.oauth_token(params[:code], oauth_redirect_integrations_discord_index_url)
    parsed = oauth_response.parsed_response
    parsed = nil if !parsed.is_a?(Hash)
    server = parsed&.dig("guild")
    access_token = parsed&.dig("access_token")
    return render json: { success: false } unless oauth_response.success? && server.present? && access_token.present?

    begin
      user_response = discord_api.identify(access_token)

      user = JSON.parse(user_response)
      render json: { success: true, server_id: server["id"], server_name: server["name"], username: user["username"] }
    rescue Discordrb::Errors::CodeError, JSON::ParserError
      render json: { success: false }
    end
  end

  def join_server
    # Fail fast on an unowned purchase before spending a Discord OAuth exchange.
    return render json: { success: false } if params[:code].blank? || params[:purchase_id].blank?

    purchase = Purchase.find_by_external_id(params[:purchase_id])
    return render json: { success: false } unless discord_purchase_authorized?(purchase)

    discord_api = DiscordApi.new
    oauth_response = discord_api.oauth_token(params[:code], oauth_redirect_integrations_discord_index_url(host: DOMAIN, protocol: PROTOCOL))
    parsed = oauth_response.parsed_response
    access_token = parsed.is_a?(Hash) ? parsed.dig("access_token") : nil

    return render json: { success: false } unless oauth_response.success? && access_token.present?

    begin
      user_response = discord_api.identify(access_token)
      user = JSON.parse(user_response)

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
    rescue Discordrb::Errors::CodeError, Discordrb::Errors::NoPermission, JSON::ParserError
      render json: { success: false }
    end
  end

  def leave_server
    return render json: { success: false } if params[:purchase_id].blank?

    purchase = Purchase.find_by_external_id(params[:purchase_id])
    return render json: { success: false } unless discord_purchase_authorized?(purchase)

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

  private
    # The purchase's external id is public (echoed on product reviews), so an id alone
    # must not grant control of its Discord membership. Accept either the signed-in
    # purchaser or possession of the purchase's download token — the same per-purchase
    # secret the download page already gates on, which keeps account-free guest
    # purchasers working without shipping the id-only bypass.
    def discord_purchase_authorized?(purchase)
      return false if purchase.nil?
      return true if current_user.present? && purchase.purchaser == current_user

      token = params[:token]
      token.present? && UrlRedirect.exists?(token:, purchase_id: purchase.id)
    end
end
