# frozen_string_literal: true

class Api::V2::MuseController < Api::V2::BaseController
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
    render json: Muse::Mcp.oauth_metadata(base_url)
  end

  def mcp_discovery
    render json: Muse::Mcp.discovery(base_url)
  end

  def protected_resource_metadata
    path = params[:resource_path].to_s
    path = "/#{path}" if path.present? && !path.start_with?("/")
    path = "/muse/v1/mcp" if path.blank?
    render json: Muse::Mcp.protected_resource_metadata(base_url, resource_path: path)
  end

  def register
    payload = Muse::OauthClientRegistration.create!(JSON.parse(request.raw_post.presence || "{}"))
    render json: payload, status: :created
  rescue JSON::ParserError
    render json: { error: "invalid_client_metadata", error_description: "JSON parse error" }, status: :bad_request
  rescue Muse::OauthClientRegistration::Error => e
    render json: { error: "invalid_client_metadata", error_description: e.message }, status: :bad_request
  end

  def mcp
    if request.get?
      response.headers["Allow"] = "POST"
      return head :method_not_allowed
    end

    result = Muse::Mcp.new(user: current_resource_owner, token: doorkeeper_token).handle(@rpc_body)
    return head :accepted if result.nil?

    status = result.is_a?(Hash) && result[:error] ? rpc_http_status(result[:error][:code]) : :ok
    render json: result, status:
  end

  private
    def validate_mcp_origin
      origin = request.headers["Origin"]
      head :forbidden unless origin.nil? || origin == base_url
    end

    def doorkeeper_unauthorized_render_options(*)
      response.set_header(
        "WWW-Authenticate",
        %(Bearer realm="Gumroad", resource_metadata="#{base_url}/.well-known/oauth-protected-resource#{request.path}")
      )
      nil
    end

    def parse_rpc_body
      return unless request.post?

      @rpc_body = JSON.parse(request.raw_post)
    rescue JSON::ParserError
      render json: { jsonrpc: "2.0", id: nil, error: { code: -32700, message: "Parse error" } }, status: :bad_request
    end

    def rpc_http_status(code)
      case code
      when -32700, -32600 then :bad_request
      # Method and parameter errors need a successful transport to reach the RPC caller.
      else :ok
      end
    end

    def base_url
      "#{PROTOCOL}://#{DOMAIN}"
    end
end
