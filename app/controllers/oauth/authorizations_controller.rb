# frozen_string_literal: true

class Oauth::AuthorizationsController < Doorkeeper::AuthorizationsController
  ADMIN_SCOPE_OPTIONAL = "optional"
  ADMIN_AUTHORIZATION_PARAM = "authorize_admin_operations"

  before_action :hide_layouts
  before_action :default_to_authorization_code
  before_action :hide_from_search_results

  helper_method :admin_scope_optional?, :show_admin_authorization_checkbox?

  private
    # Dynamically registered MCP clients must send an S256 challenge and a supported resource on
    # every authorization request, including ones on the canonical /oauth path.
    def pre_auth
      @pre_auth ||= Muse::DynamicClientOauth.screen(super)
    end

    # Only dynamic clients bind grants to a resource; other applications never persist one.
    def pre_auth_params
      fields = super
      dynamic_client_request? ? fields : fields.except(:resource)
    end

    def dynamic_client_request?
      return @dynamic_client_request if defined?(@dynamic_client_request)

      @dynamic_client_request = OauthApplication.alive.where(mcp_dynamic_client: true).exists?(uid: params[:client_id].to_s)
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

      oauth_application.with_lock do
        @pre_auth = nil
        @strategy = nil
        super
      end
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
