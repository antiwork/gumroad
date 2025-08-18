# frozen_string_literal: true

require "cgi"

module VisibleScopes
  # Public Method: public_scopes
  # These are the scopes that the public should be aware of. Update this list when adding scopes to Doorkeeper.
  # Mobile Api scope is not included because we don't want the public to have knowledge of that scope.
  def public_scopes
    %i[edit_products view_sales mark_sales_as_shipped refund_sales revenue_share ifttt view_profile view_payouts]
  end
end

Doorkeeper.configure do
  base_controller "ApplicationController"
  orm :active_record

  # This block will be called to check whether the resource owner is
  # authenticated or not.
  resource_owner_authenticator do
    current_user.presence || redirect_to("/oauth/login?next=#{CGI.escape request.fullpath}")
  end

  admin_authenticator do |_routes|
    current_user.presence || redirect_to("/oauth/login?next=#{CGI.escape request.fullpath}")
  end

  # From https://github.com/doorkeeper-gem/doorkeeper/wiki/Using-Resource-Owner-Password-Credentials-flow
  resource_owner_from_credentials do |_routes|
    if params.key?(:facebookToken)
      profile = User.fb_object("me", token: params[:facebookToken])
      user =  User.find_by(facebook_uid: profile["id"])
    elsif params.key?(:twitterToken)
      user = User.where(twitter_oauth_token: params[:twitterToken]).first
    elsif params.key?(:appleAuthorizationCode) && params.key?(:appleAppType)
      user = User.find_for_apple_auth(authorization_code: params[:appleAuthorizationCode], app_type: params[:appleAppType])
    elsif params.key?(:googleIdToken)
      user = User.find_for_google_mobile_auth(google_id_token: params[:googleIdToken])
    else
      next if params[:username].blank?
      user = User.where("username = ? OR email = ?", params[:username], params[:username]).first || User.where("unconfirmed_email = ?", params[:username]).first
      next unless user&.valid_password?(params[:password])
    end
    user if user&.alive?
  end

  authorization_code_expires_in 10.minutes
  access_token_expires_in nil

  force_ssl_in_redirect_uri false

  # Each application needs an owner
  enable_application_owner confirmation: true

  # access token scopes for providers
  default_scopes :view_public
  optional_scopes :edit_products, :view_sales, :view_payouts, :mark_sales_as_shipped, :refund_sales, :revenue_share, :ifttt, :mobile_api,
                  :creator_api, :view_profile, :unfurl, :helper_api

  use_refresh_token

  grant_flows %w[authorization_code client_credentials password]
end

Doorkeeper.configuration.extend(VisibleScopes)
