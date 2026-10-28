# frozen_string_literal: true

class Oauth::AuthorizationsController < Doorkeeper::AuthorizationsController
  ADMIN_SCOPE_OPTIONAL = "optional"
  ADMIN_AUTHORIZATION_PARAM = "authorize_admin_operations"
  LOCK_RETRY_AFTER_SECONDS = 5
  LOCK_BUSY_MESSAGE = "Gumroad is busy finishing another change to this application. Please wait a few seconds, then try again."

  rescue_from OauthApplication::LockUnavailable, with: :render_authorization_busy

  before_action :hide_layouts
  before_action :default_to_authorization_code
  before_action :hide_from_search_results

  helper_method :admin_scope_optional?, :show_admin_authorization_checkbox?

  private
    # Dynamically registered MCP clients must send an S256 challenge and a supported resource on
    # every authorization request, including ones on the canonical /oauth path.
    def pre_auth
      @pre_auth ||= Mcp::DynamicClientOauth.screen(super)
    end

    # Only dynamic clients bind grants to a resource; other applications never persist one.
    # A dynamic client that omits `scope` gets the scopes it registered, not Doorkeeper's default
    # (view_public only): the consent page grants only what the request names, so the default
    # would leave the token unable to reach the tools the client registered for.
    def pre_auth_params
      fields = super
      return fields.except(:resource) unless dynamic_client_request?

      fields[:scope] = dynamic_client_application.scopes.to_s if fields[:scope].blank?
      fields
    end

    def dynamic_client_application
      return @dynamic_client_application if defined?(@dynamic_client_application)

      @dynamic_client_application = OauthApplication.alive.where(mcp_dynamic_client: true).find_by(uid: params[:client_id].to_s)
    end

    def dynamic_client_request?
      dynamic_client_application.present?
    end

    # Doorkeeper refuses its matching-token consent skip whenever any custom access token attribute
    # is configured. `resource` is only ever set for dynamic clients, which always see consent, so
    # discount it here and keep the skip for other confidential clients exactly as before.
    def can_authorize_response?
      return false if dynamic_client_request?

      other_custom_attributes = Doorkeeper.config.custom_access_token_attributes.map(&:to_sym) - [:resource]
      other_custom_attributes.empty? && pre_auth.client.application.confidential? && matching_token?
    end

    # Scope migrations lock the application while revoking credentials. Re-read
    # and validate the requested scopes under that same lock so a request that
    # saw the old scopes cannot create a grant after the revocation sweep.
    def authorize_response
      oauth_application = OauthApplication.alive.find_by(uid: params[:client_id])
      return super if oauth_application.nil?

      oauth_application.with_application_lock(shared: true) do
        @pre_auth = nil
        @strategy = nil
        super
      end
    end

    # Nothing was written; the sweep that held the row commits within seconds.
    def render_authorization_busy(exception)
      ErrorNotifier.notify(exception, client_id: params[:client_id])
      response.set_header("Retry-After", LOCK_RETRY_AFTER_SECONDS.to_s)
      render :error, locals: { error_description: LOCK_BUSY_MESSAGE }, status: :service_unavailable
    end

    def redirect_or_render(auth)
      if admin_authorization_redirect?(auth)
        admin_authorization_code = AdminApiAuthorizationCode.create_for!(
          actor_user: current_user,
          code_challenge: pre_auth.code_challenge
        )

        redirect_to redirect_uri_with_admin_authorization_code(auth.redirect_uri, admin_authorization_code), allow_other_host: true
      else
        super
      end
    end

    def pre_auth_param_fields
      super + %i[admin_scope]
    end

    def hide_layouts
      @hide_layouts = true
    end

    def hide_from_search_results
      headers["X-Robots-Tag"] = "noindex"
    end

    def default_to_authorization_code
      params[:response_type] = "code" if params[:response_type].blank?
    end

    def admin_authorization_redirect?(auth)
      auth.redirectable? &&
        !Doorkeeper.configuration.api_only &&
        !pre_auth.form_post_response? &&
        auth.body[:code].present? &&
        show_admin_authorization_checkbox? &&
        admin_authorization_selected?
    end

    def show_admin_authorization_checkbox?
      admin_scope_optional? && current_user&.is_team_member? && pre_auth.code_challenge.present?
    end

    def admin_scope_optional?
      params[:admin_scope] == ADMIN_SCOPE_OPTIONAL
    end

    def admin_authorization_selected?
      ActiveModel::Type::Boolean.new.cast(params[ADMIN_AUTHORIZATION_PARAM])
    end

    def redirect_uri_with_admin_authorization_code(redirect_uri, admin_authorization_code)
      uri = URI.parse(redirect_uri)

      if uri.fragment.present? && Rack::Utils.parse_nested_query(uri.fragment).key?("code")
        uri.fragment = Rack::Utils.parse_nested_query(uri.fragment).merge("admin_code" => admin_authorization_code).to_query
      else
        uri.query = Rack::Utils.parse_nested_query(uri.query).merge("admin_code" => admin_authorization_code).to_query
      end

      uri.to_s
    end
end
