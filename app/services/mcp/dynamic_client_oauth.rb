# frozen_string_literal: true

module Mcp
  # Authorization-server rules for clients created by dynamic registration (RFC 7591). They are
  # keyed on the persisted `oauth_applications.mcp_dynamic_client` flag, so manually created and
  # first-party applications never reach them and keep Doorkeeper's default behaviour.
  module DynamicClientOauth
    CONNECTORS = %w[muse claude chatgpt cursor antigravity].freeze
    CODE_CHALLENGE_METHOD = "S256"
    # Added after some clients registered; a client that predates it may gain it when the person consents.
    LATE_SCOPES = %w[view_library].freeze

    class ErrorResponse < Doorkeeper::OAuth::ErrorResponse
      attr_reader :description

      def initialize(name:, description:, state:, redirect_uri:)
        super(name:, state:, redirect_uri:)
        @description = description
      end

      def exception_class
        Doorkeeper::Errors::InvalidRequest
      end
    end

    # A pre-authorization that passed Doorkeeper's own checks but not ours. Doorkeeper's
    # controllers render or redirect it exactly like one of their own failed validations.
    class RejectedPreAuthorization < SimpleDelegator
      attr_reader :error_response

      def initialize(pre_auth, error_response)
        super(pre_auth)
        @error_response = error_response
      end

      def authorizable?
        false
      end
    end

    def self.base_url
      "#{PROTOCOL}://#{DOMAIN}"
    end

    def self.resource_identifier(path)
      "#{base_url}#{path}"
    end

    def self.resource_identifiers
      CONNECTORS.map { |client| resource_identifier("/#{client}/v1/mcp") }
    end

    def self.screen(pre_auth)
      authorizable = pre_auth.authorizable?
      application = pre_auth.client&.application
      return pre_auth unless application&.mcp_dynamic_client

      unless authorizable
        return pre_auth unless pre_auth.error == Doorkeeper::Errors::InvalidScope

        pre_auth = accept_late_scopes(pre_auth, application)
        unless pre_auth.authorizable?
          return pre_auth unless pre_auth.error == Doorkeeper::Errors::InvalidScope && registrable_scopes?(pre_auth.scope)

          return explain_unknown_scope(pre_auth, application)
        end
      end

      error = authorization_error(
        code_challenge: pre_auth.code_challenge,
        code_challenge_method: pre_auth.code_challenge_method,
        resource: pre_auth.custom_access_token_attributes["resource"]
      )
      return pre_auth if error.nil?

      name, description = error
      RejectedPreAuthorization.new(
        pre_auth,
        ErrorResponse.new(name:, description:, state: pre_auth.state, redirect_uri: pre_auth.redirect_uri)
      )
    end

    def self.late_scopes_for(application, requested)
      registered = application.scopes.to_s.split
      missing = requested.to_s.split - registered
      missing.presence if missing.all? { LATE_SCOPES.include?(_1) }
    end

    # Validates the request as if the client had registered the late scope. Nothing is saved until
    # the person consents (see grant_late_scopes!).
    def self.accept_late_scopes(pre_auth, application)
      return pre_auth if late_scopes_for(application, pre_auth.scope).blank?

      widened = Doorkeeper::OAuth::Scopes.from_string((application.scopes.to_s.split + LATE_SCOPES).uniq.join(" "))
      pre_auth.define_singleton_method(:validate_scopes) do
        Doorkeeper::OAuth::Helpers::ScopeChecker.valid?(
          scope_str: scope, server_scopes: Doorkeeper.config.scopes, app_scopes: widened, grant_type: send(:grant_type)
        )
      end
      pre_auth
    end

    def self.grant_late_scopes!(application, requested)
      missing = late_scopes_for(application, requested)
      return if missing.blank?

      application.update!(scopes: (application.scopes.to_s.split + missing).uniq.join(" "))
    end

    # Registering again only helps when registration would grant every requested scope.
    def self.registrable_scopes?(scope)
      scope.to_s.split(/ +/).all? { Mcp::OauthClientRegistration::MCP_SCOPES.include?(_1) || Mcp::OauthClientRegistration::LEGACY_SCOPES.include?(_1) }
    end

    def self.explain_unknown_scope(pre_auth, application)
      # Registration stores the client's own name behind "MCP ", or "MCP client" when it sent none.
      client = application.name.delete_prefix("MCP ")
      client = "your AI app" if client == "client"
      # Only a new registration carries the new scopes, so the fix is on the client's side.
      description = "#{client.upcase_first} can't connect to Gumroad because it asked for a permission it was not set up with. " \
                    "Remove Gumroad from #{client}, then add it again."
      RejectedPreAuthorization.new(
        pre_auth,
        ErrorResponse.new(name: :invalid_scope, description:, state: pre_auth.state, redirect_uri: pre_auth.redirect_uri)
      )
    end

    def self.authorization_error(code_challenge:, code_challenge_method:, resource:)
      if code_challenge.blank? || code_challenge_method != CODE_CHALLENGE_METHOD
        return [:invalid_request, "code_challenge with code_challenge_method #{CODE_CHALLENGE_METHOD} is required"]
      end
      return [:invalid_target, "resource is required"] if resource.blank?
      return [:invalid_target, "resource is not a supported MCP resource"] unless resource_identifiers.include?(resource)

      nil
    end

    def self.code_exchange_error(grant, resource:, code_verifier:)
      return unless grant.application&.mcp_dynamic_client

      unless grant.code_challenge.present? && grant.code_challenge_method == CODE_CHALLENGE_METHOD
        return [:invalid_grant, "authorization code was not issued with an #{CODE_CHALLENGE_METHOD} code challenge"]
      end
      return [:invalid_request, "code_verifier is required"] if code_verifier.blank?
      return [:invalid_grant, "authorization code has no bound resource"] if grant.resource.blank?
      return [:invalid_target, "resource does not match the authorization request"] if resource.present? && resource != grant.resource

      nil
    end

    def self.refresh_error(token, resource:)
      return unless token.application&.mcp_dynamic_client
      return [:invalid_grant, "refresh token has no bound resource"] if token.resource.blank?
      return [:invalid_target, "resource does not match the refresh token"] if resource.present? && resource != token.resource

      nil
    end

    # A token bound to a resource is only valid when presented at that resource (RFC 8707).
    # Anywhere else it counts as absent, so Doorkeeper answers 401 like for any unknown token.
    def self.token_for_request(token, request)
      return token if token.nil? || token.resource.blank?

      token if token.resource == resource_identifier(request.path)
    end
  end
end
