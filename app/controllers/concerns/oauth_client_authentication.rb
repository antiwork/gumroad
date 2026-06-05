# frozen_string_literal: true

module OauthClientAuthentication
  extend ActiveSupport::Concern

  private
    def authenticate_oauth_application
      client_id, client_secret = oauth_client_credentials
      return [nil, :invalid_request, "client_id is required"] if client_id.blank?

      oauth_application = OauthApplication.alive.find_by(uid: client_id)
      return [nil, :invalid_client, "Client authentication failed due to unknown client"] if oauth_application.blank?
      return [oauth_application, nil, nil] unless oauth_application.confidential?
      return [oauth_application, nil, nil] if valid_oauth_client_secret?(oauth_application, client_secret)

      [nil, :invalid_client, "Client authentication failed"]
    end

    def requested_oauth_scope_for(oauth_application)
      requested_scope = params[:scope]
      return requested_scope if requested_scope.is_a?(String) && requested_scope.present?
      return if requested_scope.present?

      oauth_application_scopes(oauth_application).to_s
    end

    def valid_oauth_scope?(oauth_application, scopes)
      return false unless scopes.is_a?(String) && scopes.present?

      Doorkeeper::OAuth::Helpers::ScopeChecker.valid?(
        scope_str: scopes,
        server_scopes: Doorkeeper.configuration.scopes,
        app_scopes: oauth_application_scopes(oauth_application)
      )
    end

    def render_oauth_json_error(error, description, status: :bad_request, extra: {})
      headers.merge!("Cache-Control" => "no-store, no-cache")
      headers["WWW-Authenticate"] = %(Basic realm="Doorkeeper") if basic_oauth_authentication_failure?(status)
      render json: { error:, error_description: description }.merge(extra), status:
    end

    def basic_oauth_authentication_failure?(status)
      status == :unauthorized && ActionController::HttpAuthentication::Basic.has_basic_credentials?(request)
    end

    def oauth_request_user_agent
      request.user_agent.to_s.first(255)
    end

    def oauth_client_credentials
      basic_client_id, basic_client_secret = ActionController::HttpAuthentication::Basic.user_name_and_password(request)
      [params[:client_id].presence || basic_client_id, params[:client_secret].presence || basic_client_secret]
    end

    def valid_oauth_client_secret?(oauth_application, client_secret)
      return false if client_secret.blank?
      return false if oauth_application.secret.bytesize != client_secret.to_s.bytesize

      ActiveSupport::SecurityUtils.secure_compare(oauth_application.secret, client_secret.to_s)
    end

    def oauth_application_scopes(oauth_application)
      Doorkeeper::OAuth::Scopes.from_string(oauth_application.scopes.to_s)
    end
end
