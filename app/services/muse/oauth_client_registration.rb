# frozen_string_literal: true

module Muse
  class OauthClientRegistration
    class Error < StandardError; end

    MCP_SCOPES = %w[view_public view_profile view_sales edit_products view_payouts account].freeze
    NAME_MAX = 80
    REDIRECT_URIS_MAX = 10
    # oauth_applications.redirect_uri (newline-joined) and oauth_access_grants.redirect_uri are
    # varchar(255), and the session sql_mode is non-strict, so MySQL truncates instead of raising.
    REDIRECT_URIS_MAX_LENGTH = 255

    def self.create!(params)
      new(params).create!
    end

    def initialize(params)
      @params = params.is_a?(Hash) ? params : {}
    end

    def create!
      redirect_uris = normalized_redirect_uris
      raise Error, "redirect_uris is required" if redirect_uris.empty?

      redirect_uris.each { |uri| validate_redirect_uri!(uri) }
      redirect_uri = redirect_uris.join("\n")
      raise Error, "redirect_uris must be at most #{REDIRECT_URIS_MAX_LENGTH} characters combined" if redirect_uri.length > REDIRECT_URIS_MAX_LENGTH

      application = OauthApplication.new(
        name: client_name,
        redirect_uri:,
        confidential: confidential?,
        scopes: assigned_scopes,
        mcp_dynamic_client: true
      )
      # Dynamic clients are not owned by a Gumroad user.
      application.define_singleton_method(:validate_owner?) { false }

      raise Error, application.errors.full_messages.to_sentence unless application.save

      payload = {
        client_id: application.uid,
        client_id_issued_at: application.created_at.to_i,
        redirect_uris:,
        grant_types: %w[authorization_code refresh_token],
        response_types: ["code"],
        token_endpoint_auth_method: token_endpoint_auth_method,
        scope: application.scopes.to_s
      }
      payload[:client_secret] = application.secret if application.confidential?
      payload
    end

    private
      def normalized_redirect_uris
        raw = @params["redirect_uris"] || @params[:redirect_uris] || @params["redirect_uri"] || @params[:redirect_uri]
        raw = Array(raw).flatten
        raise Error, "redirect_uris must contain at most #{REDIRECT_URIS_MAX} entries" if raw.size > REDIRECT_URIS_MAX

        raw.map { |uri| uri.to_s.strip }.compact_blank.uniq
      end

      def client_name
        name = (@params["client_name"] || @params[:client_name]).to_s.strip
        name = "MCP client" if name.blank?
        "MCP #{name}".truncate(NAME_MAX)
      end

      def assigned_scopes
        requested = (@params["scope"] || @params[:scope]).to_s.split
        chosen = requested.presence ? (requested & MCP_SCOPES) : MCP_SCOPES
        raise Error, "no supported scopes requested" if requested.present? && chosen.empty?

        chosen.join(" ")
      end

      def token_endpoint_auth_method
        method = (@params["token_endpoint_auth_method"] || @params[:token_endpoint_auth_method]).to_s
        method = method.presence || "none"
        raise Error, "unsupported token_endpoint_auth_method" unless %w[none client_secret_post client_secret_basic].include?(method)

        method
      end

      def confidential?
        token_endpoint_auth_method != "none"
      end

      def validate_redirect_uri!(value)
        uri = URI.parse(value)
        raise Error, "redirect_uris must be absolute http(s) URLs" if uri.host.blank?
        raise Error, "redirect_uris must not include a fragment" if uri.fragment.present?

        https = uri.is_a?(URI::HTTPS)
        local_http = uri.is_a?(URI::HTTP) && %w[localhost 127.0.0.1].include?(uri.host)
        raise Error, "redirect_uris must be https (or http on localhost)" unless https || local_http
      rescue URI::InvalidURIError
        raise Error, "redirect_uris must be valid URLs"
      end
  end
end
