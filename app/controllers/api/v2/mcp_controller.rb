# frozen_string_literal: true

class Api::V2::McpController < Api::V2::BaseController
  skip_before_action :verify_authenticity_token
  # Parse before inherited callbacks access params so malformed JSON gets a JSON-RPC error.
  prepend_before_action :validate_mcp_origin, :parse_rpc_body, only: :mcp
  # view_public is the access-token default scope but is absent from public_scopes, so a
  # default-scope token was rejected here before any tool's own scope check ran.
  before_action(only: [:mcp]) { doorkeeper_authorize!(*Doorkeeper.configuration.public_scopes, :view_public) }

  def status
    render json: { status: "success" }
  end

  def oauth_metadata
    render json: Mcp::Server.oauth_metadata(base_url)
  end

  def mcp_discovery
    render json: Mcp::Server.discovery(base_url)
  end

  # OpenAI's plugin review verifies that we control the MCP host by fetching this path and
  # expecting nothing but the token it issued. JSON, an empty body, or more than one token fails.
  def openai_apps_challenge
    token = ENV["OPENAI_APPS_CHALLENGE_TOKEN"].to_s
    return head :not_found if token.blank?

    render plain: token
  end

  def protected_resource_metadata
    path = params[:resource_path].to_s
    path = "/#{path}" if path.present? && !path.start_with?("/")
    path = "/muse/v1/mcp" if path.blank?
    render json: Mcp::Server.protected_resource_metadata(base_url, resource_path: path)
  end

  def register
    payload = Mcp::OauthClientRegistration.create!(JSON.parse(request.raw_post.presence || "{}"))
    render json: payload, status: :created
  rescue JSON::ParserError
    render json: { error: "invalid_client_metadata", error_description: "JSON parse error" }, status: :bad_request
  rescue Mcp::OauthClientRegistration::Error => e
    render json: { error: "invalid_client_metadata", error_description: e.message }, status: :bad_request
  end

  def mcp
    if request.get?
      response.headers["Allow"] = "POST"
      return head :method_not_allowed
    end

    mcp = Mcp::Server.new(
      user: current_resource_owner,
      token: doorkeeper_token,
      connector: params[:client],
      protocol_version_header: request.headers[Mcp::Server::VERSION_HEADER],
      method_header: request.headers[Mcp::Server::METHOD_HEADER],
      name_header: request.headers[Mcp::Server::NAME_HEADER]
    )
    result = mcp.handle(@rpc_body)
    return head :accepted if result.nil?

    if mcp.insufficient_scope
      # MCP scope challenge: the header names the scopes to step up to; the body keeps the text.
      response.set_header("WWW-Authenticate", bearer_challenge(
        error: "insufficient_scope", scope: mcp.insufficient_scope.scope, error_description: mcp.insufficient_scope.message
      ))
      return render json: result, status: :forbidden
    end

    render json: result, status: rpc_http_status(result, era: mcp.era)
  end

  private
    def validate_mcp_origin
      origin = request.headers["Origin"]
      head :forbidden unless origin.nil? || origin == base_url
    end

    def doorkeeper_unauthorized_render_options(*)
      response.set_header("WWW-Authenticate", bearer_challenge(scope: Mcp::OauthClientRegistration::MCP_SCOPES.join(" ")))
      nil
    end

    # `scope` tells a client which scopes to request before it authorizes (401) or re-authorizes
    # (403). Every value is ours, so none needs quoting.
    def bearer_challenge(error_description: nil, **params)
      params = { realm: "Gumroad", **params, resource_metadata: "#{base_url}/.well-known/oauth-protected-resource#{request.path}", error_description: }.compact
      "Bearer #{params.map { |name, value| %(#{name}="#{value}") }.join(', ')}"
    end

    def parse_rpc_body
      return unless request.post?

      @rpc_body = JSON.parse(request.raw_post)
    rescue JSON::ParserError
      render json: { jsonrpc: "2.0", id: nil, error: { code: -32700, message: "Parse error" } }, status: :bad_request
    end

    def rpc_http_status(result, era:)
      return :ok unless result.is_a?(Hash) && result[:error]

      case result[:error][:code]
      when -32700, -32600, Mcp::Server::HEADER_MISMATCH, Mcp::Server::UNSUPPORTED_PROTOCOL_VERSION then :bad_request
      # Only a modern client is told at the transport level that the method does not exist.
      when -32601 then era == :modern ? :not_found : :ok
      # Method and parameter errors need a successful transport to reach the RPC caller.
      else :ok
      end
    end

    def base_url
      "#{PROTOCOL}://#{DOMAIN}"
    end
end
