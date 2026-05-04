# frozen_string_literal: true

class Oauth::AuthorizationsController < Doorkeeper::AuthorizationsController
  ADMIN_SCOPE_OPTIONAL = "optional"
  ADMIN_AUTHORIZATION_PARAM = "authorize_admin_operations"

  before_action :hide_layouts
  before_action :default_to_authorization_code
  before_action :hide_from_search_results

  helper_method :admin_scope_optional?, :show_admin_authorization_checkbox?

  private
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
