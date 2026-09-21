# frozen_string_literal: true

module Muse
  # Authorization-server rules for clients created by dynamic registration (RFC 7591). They are
  # keyed on the persisted `oauth_applications.mcp_dynamic_client` flag, so manually created and
  # first-party applications never reach them and keep Doorkeeper's default behaviour.
  module DynamicClientOauth
    CONNECTORS = %w[muse claude chatgpt].freeze
    CODE_CHALLENGE_METHOD = "S256"

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
      return pre_auth unless pre_auth.authorizable? && pre_auth.client.application.mcp_dynamic_client

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
