# frozen_string_literal: true

class Oauth::DeviceCodesController < ApplicationController
  include OauthClientAuthentication

  skip_before_action :verify_authenticity_token

  def create
    oauth_application, error, error_description = authenticate_oauth_application
    return render_oauth_json_error(error, error_description, status: error == :invalid_client ? :unauthorized : :bad_request) if error

    result = oauth_application.with_lock do
      if !oauth_application.device_authorization_enabled?
        { error: :unauthorized_client, error_description: "Client is not allowed to use device authorization" }
      else
        scopes = requested_oauth_scope_for(oauth_application)
        if valid_oauth_scope?(oauth_application, scopes)
          device_authorization, device_code, user_code = OauthDeviceAuthorization.create_for!(
            oauth_application:,
            scopes:,
            ip_address: request.remote_ip,
            user_agent: oauth_request_user_agent
          )
          { device_authorization:, device_code:, user_code: }
        else
          { error: :invalid_scope, error_description: "The requested scope is invalid" }
        end
      end
    end

    return render_oauth_json_error(result[:error], result[:error_description]) if result[:error]

    headers.merge!("Cache-Control" => "no-store, no-cache")
    render json: {
      device_code: result[:device_code],
      user_code: result[:user_code],
      verification_uri: oauth_device_authorization_url(host: DOMAIN, protocol: PROTOCOL),
      verification_uri_complete: oauth_device_authorization_url(host: DOMAIN, protocol: PROTOCOL, user_code: result[:user_code]),
      expires_in: OauthDeviceAuthorization::EXPIRES_IN.to_i,
      interval: OauthDeviceAuthorization::POLL_INTERVAL.to_i,
    }
  end
end
