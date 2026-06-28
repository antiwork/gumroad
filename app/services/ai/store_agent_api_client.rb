# frozen_string_literal: true

# Ai::StoreAgentApiClient gives the store agent maximal, properly-authorized access to the creator's
# own Gumroad data by calling the REAL public v2 API in-process, authenticated with a short-lived
# OAuth access token minted for that creator. This means every tool the agent exposes reuses the
# exact authorization (Doorkeeper scopes), validation, and serialization the documented public API
# already enforces — the agent can never do anything the creator couldn't do with their own API
# token, and we don't reimplement per-endpoint logic or auth.
#
# Safety model:
#   - The token is scoped to the SINGLE creator (resource_owner_id), expires in 5 minutes, is created
#     per agent turn, and is revoked immediately after the turn. It never leaves the server and is
#     never shown to the LLM or the browser.
#   - The token's scopes are the creator's own; an endpoint the creator's role can't reach 403s.
#   - GET (read) calls run automatically. NON-GET (write) calls are NOT executed here — the caller
#     (StoreAgentService) turns them into a proposed action the creator must confirm, and only then
#     does StoreAgentActionExecutor replay the same request to mutate.
class Ai::StoreAgentApiClient
  # The dedicated first-party OAuth application that backs the agent. Owned by the creator so the
  # token's application owner and resource owner are the same account. Scopes cover the full public
  # surface; the per-endpoint doorkeeper_authorize! still gates each call to what the creator's role
  # actually permits.
  AGENT_APP_NAME = "Gumroad Store Agent (internal)"
  # The full public scope set plus `account` (Api::V2::BaseController#doorkeeper_authorize! appends
  # :account to every endpoint's check, so the token must carry it). These are the SAME scopes a
  # creator can grant their own API integration; the per-endpoint authorize! and Pundit role checks
  # still gate each call, so a role that can't refund/edit simply 403s.
  AGENT_APP_SCOPES = "view_public account edit_products view_sales view_payouts edit_sales " \
                     "refund_sales mark_sales_as_shipped edit_emails view_profile edit_profile view_tax_data"
  TOKEN_TTL_SECONDS = 300

  def initialize(seller:)
    @seller = seller
  end

  # Run a read (GET) request against the v2 API as the creator. Returns a parsed Hash.
  def get(path, params = {})
    request(:get, path, params)
  end

  # Run a mutating request (post/put/patch/delete). Used by the executor AFTER the creator confirms.
  def write(method, path, params = {})
    request(method.to_sym, path, params)
  end

  private
    attr_reader :seller

    def request(method, path, params)
      token = mint_token
      session = ActionDispatch::Integration::Session.new(Rails.application)
      session.host! api_host
      # The v2 API is mounted at /v2/... on the API domain (ApiDomainConstraint). Accept a caller path
      # with or without the leading "v2/" and normalize to the canonical "/v2/<path>".
      normalized = path.delete_prefix("/").delete_prefix("api/").delete_prefix("v2/")
      full_path = "/v2/#{normalized}"
      headers = { "Authorization" => "Bearer #{token.token}", "Accept" => "application/json" }

      case method
      when :get then session.get(full_path, params:, headers:)
      when :post then session.post(full_path, params:, headers:)
      when :put then session.put(full_path, params:, headers:)
      when :patch then session.patch(full_path, params:, headers:)
      when :delete then session.delete(full_path, params:, headers:)
      else
        return { "success" => false, "message" => "Unsupported method #{method}." }
      end

      parse(session.response)
    ensure
      token&.revoke
    end

    def parse(response)
      body = response.body.to_s
      json = body.present? ? JSON.parse(body) : {}
      json.is_a?(Hash) ? json.merge("http_status" => response.status) : { "data" => json, "http_status" => response.status }
    rescue JSON::ParserError
      { "success" => false, "message" => "The API returned an unreadable response.", "http_status" => response.status }
    end

    def mint_token
      Doorkeeper::AccessToken.create!(
        application: agent_application,
        resource_owner_id: seller.id,
        scopes: agent_application.scopes.to_s,
        expires_in: TOKEN_TTL_SECONDS,
        use_refresh_token: false,
      )
    end

    # One agent OAuth app per creator (owned by them). find_or_create keeps it stable across turns.
    def agent_application
      @_app ||= OauthApplication.find_or_create_by!(name: AGENT_APP_NAME, owner: seller) do |app|
        app.redirect_uri = "urn:ietf:wg:oauth:2.0:oob"
        app.scopes = AGENT_APP_SCOPES
      end
    end

    def api_host
      # The v2 API is served on the API domain in every environment (it's also reachable on the main
      # domain, but API_DOMAIN is the canonical host the routes/controllers expect). Fall back to the
      # main domain, then localhost, so a misconfigured env still dispatches somewhere valid.
      (defined?(API_DOMAIN) && API_DOMAIN.presence) ||
        (defined?(DOMAIN) && DOMAIN.presence) ||
        (Rails.application.config.action_controller.default_url_options || {})[:host] ||
        "localhost"
    end
end
