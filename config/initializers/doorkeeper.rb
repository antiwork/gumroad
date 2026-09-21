# frozen_string_literal: true

require "cgi"

module VisibleScopes
  # Public Method: public_scopes
  # These are the scopes that the public should be aware of. Update this list when adding scopes to Doorkeeper.
  # Mobile Api scope is not included because we don't want the public to have knowledge of that scope.
  def public_scopes
    %i[edit_products edit_emails view_sales mark_sales_as_shipped edit_sales revenue_share ifttt view_profile edit_profile view_payouts view_tax_data account]
  end

  def public_api_read_scopes
    public_scopes - %i[edit_emails edit_profile]
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

  authorization_code_expires_in 10.minutes
  access_token_expires_in nil

  force_ssl_in_redirect_uri false

  # Each application needs an owner
  enable_application_owner confirmation: true

  # access token scopes for providers
  default_scopes :view_public
  optional_scopes :edit_products, :edit_emails, :view_sales, :view_payouts, :mark_sales_as_shipped, :refund_sales, :edit_sales, :revenue_share, :ifttt, :mobile_api,
                  :creator_api, :view_profile, :edit_profile, :unfurl, :helper_api, :view_tax_data, :account

  use_refresh_token

  grant_flows %w[authorization_code client_credentials]

  # Grants and tokens for dynamically registered MCP clients carry the resource they were
  # requested for (RFC 8707); Doorkeeper copies it grant → token → refreshed token. Other
  # applications never receive the parameter (see Oauth::AuthorizationsController#pre_auth_params).
  custom_access_token_attributes [:resource]

  # Dynamic registration advertises authorization_code (+ refresh) only.
  allow_grant_flow_for_client do |grant_flow, client|
    !client&.mcp_dynamic_client || grant_flow == Doorkeeper::OAuth::AUTHORIZATION_CODE
  end

  skip_authorization do |_resource_owner, client|
    client.uid == OauthApplication::MOBILE_API_OAUTH_APPLICATION_UID
  end
end

Doorkeeper.configuration.extend(VisibleScopes)
