# frozen_string_literal: true

require "cgi"

module VisibleScopes
  # Public Method: public_scopes
  # These are the scopes that the public should be aware of. Update this list when adding scopes to Doorkeeper.
  # Mobile Api scope is not included because we don't want the public to have knowledge of that scope.
  def public_scopes
    %i[edit_products view_sales mark_sales_as_shipped edit_sales revenue_share ifttt view_profile view_payouts view_tax_data account]
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
  optional_scopes :edit_products, :view_sales, :view_payouts, :mark_sales_as_shipped, :refund_sales, :edit_sales, :revenue_share, :ifttt, :mobile_api,
                  :creator_api, :view_profile, :unfurl, :helper_api, :view_tax_data, :account

  use_refresh_token

  grant_flows %w[authorization_code client_credentials]

  skip_authorization do |_resource_owner, client|
    client.uid == OauthApplication::MOBILE_API_OAUTH_APPLICATION_UID
  end
end

Doorkeeper.configuration.extend(VisibleScopes)
