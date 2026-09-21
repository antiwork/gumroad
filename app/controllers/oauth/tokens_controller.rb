# frozen_string_literal: true

class Oauth::TokensController < Doorkeeper::TokensController
  include OauthClientAuthentication
  include LogrageHelper

  def create
    return create_device_access_token if device_access_token_request?

    error = dynamic_client_token_error
    return render_oauth_json_error(*error) if error

    super
  end

  private
    # Credentials issued to dynamically registered MCP clients only redeem with S256 PKCE and for
    # the resource they were granted for; other applications keep Doorkeeper's checks alone.
    def dynamic_client_token_error
      case params[:grant_type].presence || Doorkeeper::OAuth::AUTHORIZATION_CODE
      when Doorkeeper::OAuth::AUTHORIZATION_CODE
        grant = Doorkeeper.config.access_grant_model.by_token(params[:code])
        Muse::DynamicClientOauth.code_exchange_error(grant, resource: params[:resource], code_verifier: params[:code_verifier]) if grant
      when Doorkeeper::OAuth::REFRESH_TOKEN
        token = Doorkeeper.config.access_token_model.by_refresh_token(params[:refresh_token])
        Muse::DynamicClientOauth.refresh_error(token, resource: params[:resource]) if token
      end
    end

    # Doorkeeper validates an explicit refresh scope before it locks and reloads
    # the source token. Take the application lock before it builds that request
    # so a scope rollback either sweeps the replacement token or finishes first
    # and makes Doorkeeper validate against the reduced scopes.
    def authorize_response
      oauth_application = refresh_token_application
      return super if oauth_application.nil?

      oauth_application.with_lock do
        @strategy = nil
        super
      end
    end

    def refresh_token_application
      return unless params[:grant_type] == "refresh_token"

      Doorkeeper.config.access_token_model.by_refresh_token(params[:refresh_token])&.application
    end

    def device_access_token_request?
      request.path.match?(%r{\A#{Regexp.escape(oauth_token_path)}(?:\.[^/]+)?\z}) &&
        params[:grant_type] == OauthDeviceAuthorization::GRANT_TYPE
    end

    def create_device_access_token
      oauth_application, error, error_description = authenticate_oauth_application
      return render_oauth_json_error(error, error_description, status: error == :invalid_client ? :unauthorized : :bad_request) if error
      return render_oauth_json_error(:unauthorized_client, "Client is not allowed to use device authorization") unless oauth_application.device_authorization_enabled?
      return render_oauth_json_error(:invalid_request, "device_code is required") if params[:device_code].blank?

      device_authorization = OauthDeviceAuthorization.find_by_device_code(params[:device_code])
      return render_oauth_json_error(:expired_token, "Device code is invalid or expired") if device_authorization.blank?

      status, value = device_authorization.poll!(oauth_application:, ip_address: request.remote_ip, user_agent: oauth_request_user_agent)
      if status == OauthDeviceAuthorization::POLL_APPROVED
        # Re-acquire the app lock for render; render_device_access_token_response reloads the token
        # in case revoke_access_for landed after poll! released its locks.
        oauth_application.with_lock { render_device_access_token_response(status, value) }
      else
        render_device_access_token_response(status, value)
      end
    end

    def render_device_access_token_response(status, value)
      case status
      when OauthDeviceAuthorization::POLL_APPROVED
        return render_oauth_json_error(:access_denied, "Access was denied") if value.reload.revoked?

        response = Doorkeeper::OAuth::TokenResponse.new(value)
        headers.merge!(response.headers)
        render json: response.body, status: response.status
      when OauthDeviceAuthorization::POLL_AUTHORIZATION_PENDING
        render_oauth_json_error(:authorization_pending, "Authorization is pending")
      when OauthDeviceAuthorization::POLL_SLOW_DOWN
        render_oauth_json_error(:slow_down, "Polling too quickly", extra: { interval: value })
      when OauthDeviceAuthorization::POLL_ACCESS_DENIED
        render_oauth_json_error(:access_denied, "Access was denied")
      else
        render_oauth_json_error(:expired_token, "Device code is invalid or expired")
      end
    end

    def strategy
      # default to authorization code
      params[:grant_type] = "authorization_code" if params[:grant_type].blank?
      super
    end
end
