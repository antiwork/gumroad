# frozen_string_literal: true

class Oauth::DeviceCodesController < ApplicationController
  include OauthClientAuthentication

  skip_before_action :verify_authenticity_token

  def create
    oauth_application, error, error_description = authenticate_oauth_application
    return render_oauth_json_error(error, error_description, status: error == :invalid_client ? :unauthorized : :bad_request) if error
    return render_oauth_json_error(:unauthorized_client, "Client is not allowed to use device authorization") unless oauth_application.device_authorization_enabled?

    scopes = requested_oauth_scope_for(oauth_application)
    return render_oauth_json_error(:invalid_scope, "The requested scope is invalid") unless valid_oauth_scope?(oauth_application, scopes)

    _device_authorization, device_code, user_code = OauthDeviceAuthorization.create_for!(
      oauth_application:,
      scopes:,
      ip_address: request.remote_ip,
      user_agent: oauth_request_user_agent
    )

    headers.merge!("Cache-Control" => "no-store, no-cache")
    render json: {
      device_code:,
      user_code:,
      verification_uri: oauth_device_authorization_url(host: DOMAIN, protocol: PROTOCOL),
      verification_uri_complete: oauth_device_authorization_url(host: DOMAIN, protocol: PROTOCOL, user_code:),
      expires_in: OauthDeviceAuthorization::EXPIRES_IN.to_i,
      interval: OauthDeviceAuthorization::POLL_INTERVAL.to_i,
    }
  end
end
