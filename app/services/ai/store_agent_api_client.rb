# frozen_string_literal: true

# Ai::StoreAgentApiClient gives the store agent maximal, properly-authorized access to the creator's
# own Gumroad data by calling the REAL public v2 API in-process, authenticated with a short-lived
# OAuth access token minted for that creator. This means every tool the agent exposes reuses the
# exact authorization (Doorkeeper scopes), validation, and serialization the documented public API
# already enforces — the agent can never do anything the creator couldn't do with their own API
# token, and we don't reimplement per-endpoint logic or auth.
#
# Safety model:
#   - The token's RESOURCE OWNER is always the store owner (so the right records resolve), but its
#     SCOPES are narrowed to what the ACTING user's team role is allowed to drive (see
#     Ai::StoreAgentScopes). The v2 API gates each endpoint by scope only — it never consults the
#     acting team member's role — so narrowing the scopes is what stops a non-owner teammate (e.g.
#     marketing) from reaching payouts/tax/refunds the dashboard denies their role.
#   - The token expires in 5 minutes, is created per request, and is revoked immediately after. It
#     never leaves the server and is never shown to the LLM or the browser.
#   - GET (read) calls run automatically. NON-GET (write) calls are NOT executed here — the caller
#     (StoreAgentService) turns them into a proposed action the creator must confirm, and only then
#     does StoreAgentActionExecutor replay the same request to mutate.
class Ai::StoreAgentApiClient
  # The dedicated first-party OAuth application that backs the agent. Owned by the creator so the
  # token's application owner and resource owner are the same account. The app is registered with the
  # FULL scope superset; each minted token, however, carries only the subset the acting user's role
  # permits (Ai::StoreAgentScopes.permitted_for), so role narrowing happens per-token, not per-app.
  AGENT_APP_NAME = "Gumroad Store Agent (internal)"
  # The full public scope superset the agent app is registered with. Individual tokens are minted
  # with a narrowed SUBSET of these based on the acting user's role; see Ai::StoreAgentScopes.
  AGENT_APP_SCOPES = Ai::StoreAgentScopes.all_scopes_string
  TOKEN_TTL_SECONDS = 300

  # @param seller [User] the store owner (token resource owner; records resolve under this account)
  # @param pundit_user [SellerContext] the acting user + seller; its user's role narrows the scopes
  #   minted on the token. Required so a non-owner teammate can't inherit owner-level scopes.
  def initialize(seller:, pundit_user:)
    @seller = seller
    @pundit_user = pundit_user
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
    attr_reader :seller, :pundit_user

    def request(method, path, params)
      # The dispatch below runs a real, full-stack request in-process on the CURRENT thread, which
      # re-enters rack-mini-profiler. Mini-profiler keeps its per-request context in a thread-local and
      # nils it at the end of every request — including this nested one — which would wipe the OUTER
      # (real) request's context and crash it on teardown ("undefined method 'discard' for nil").
      # Snapshot and restore that thread-local around the nested call so the outer request is untouched.
      mini_profiler_context = defined?(Rack::MiniProfiler) ? Rack::MiniProfiler.current : nil
      token = mint_token
      session = ActionDispatch::Integration::Session.new(Rails.application)
      session.host! api_host
      # The v2 API is mounted at /v2/... on the API domain (ApiDomainConstraint). Accept a caller path
      # with or without the leading "v2/" and normalize to the canonical "/v2/<path>".
      normalized = path.delete_prefix("/").delete_prefix("api/").delete_prefix("v2/")
      full_path = "/v2/#{normalized}"
      headers = { "Authorization" => "Bearer #{token.token}", "Accept" => "application/json" }

      # This dispatches a full in-process request while the OUTER request already holds the Rails load
      # interlock (a shared lock). In development the nested request can need to autoload code, which
      # requires the interlock exclusively — and the reloader can't get it while we hold it shared,
      # so the two deadlock until Rack::Timeout fires. permit_concurrent_loads lets us yield the shared
      # hold for the duration of the nested request so its autoloads resolve. (No-op in production,
      # where code is eager-loaded and the interlock never blocks.)
      ActiveSupport::Dependencies.interlock.permit_concurrent_loads do
        case method
        when :get then session.get(full_path, params:, headers:)
        when :post then session.post(full_path, params:, headers:)
        when :put then session.put(full_path, params:, headers:)
        when :patch then session.patch(full_path, params:, headers:)
        when :delete then session.delete(full_path, params:, headers:)
        else
          return { "success" => false, "message" => "Unsupported method #{method}." }
        end
      end

      parse(session.response)
    ensure
      Rack::MiniProfiler.current = mini_profiler_context if defined?(Rack::MiniProfiler)
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
      # Resource owner is the store owner (records resolve under their account), but the SCOPES are
      # narrowed to what the acting user's role permits, so a non-owner teammate can't drive an
      # endpoint outside their dashboard role. A user with no permitted scopes can mint a baseline
      # token only (it can still satisfy :account but reaches no gated endpoint).
      scopes = Ai::StoreAgentScopes.permitted_for(pundit_user)
      Doorkeeper::AccessToken.create!(
        application: agent_application,
        resource_owner_id: seller.id,
        scopes: scopes.join(" "),
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
