# frozen_string_literal: true

class Api::V2::MuseController < Api::V2::BaseController
  skip_before_action :verify_authenticity_token
  before_action(only: [:mcp]) { doorkeeper_authorize!(*Doorkeeper.configuration.public_scopes) }

  def status
    render json: { status: "success" }
  end

  def oauth_metadata
    render json: Muse::Mcp.oauth_metadata(base_url)
  end

  def mcp_discovery
    render json: Muse::Mcp.discovery(base_url)
  end

  def mcp
    body = parse_rpc_body
    return render json: { jsonrpc: "2.0", id: nil, error: { code: -32700, message: "Parse error" } }, status: :bad_request if body.nil?

    result = Muse::Mcp.new(user: current_resource_owner, token: doorkeeper_token).handle(body)
    return head :no_content if result.nil?

    status = result[:error] ? rpc_http_status(result[:error][:code]) : :ok
    render json: result, status:
  end

  private
    def parse_rpc_body
      raw = request.raw_post
      return {} if raw.blank?

      JSON.parse(raw)
    rescue JSON::ParserError
      nil
    end

    def rpc_http_status(code)
      case code
      when -32700, -32600, -32602 then :bad_request
      when -32601 then :not_found
      else :ok
      end
    end

    def base_url
      "#{PROTOCOL}://#{DOMAIN}"
    end
end
