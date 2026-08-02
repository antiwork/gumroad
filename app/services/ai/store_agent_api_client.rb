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
  # Display name for the dedicated first-party OAuth app. Identity comes from
  # is_first_party_agent_app; the name carries no authorization meaning.
  AGENT_APP_NAME = "Gumroad Store Agent (internal)"
  AGENT_APP_REDIRECT_URI = "urn:ietf:wg:oauth:2.0:oob"
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

    def agent_application
      @_app ||= alive_flagged_agent_application || adopt_or_create_agent_application
    end

    # Alive-only: the backfill flags soft-deleted rows too, and a seller can delete this app from
    # Settings > Advanced without the flag being cleared. Binding to a deleted row would mint tokens
    # against an application whose deletion already revoked every grant and token it had.
    def alive_flagged_agent_application
      OauthApplication.alive.find_by(owner: seller, owner_type: "User", is_first_party_agent_app: true)
    end

    def adopt_or_create_agent_application
      seller.with_lock do
        # No `return` inside this block: the app loads Rails 7.0 defaults, where a non-local return
        # rolls the surrounding transaction back and silently discards the adoption write.
        matching_app = alive_flagged_agent_application || OauthApplication.find_by(agent_application_fingerprint)

        if matching_app.present?
          # update_column, not update!: these rows can be years old, and re-running the model's
          # validations here would brick the agent for a seller whose legacy icon or scopes no
          # longer validate.
          matching_app.update_column(:is_first_party_agent_app, true) unless matching_app.is_first_party_agent_app?
          matching_app
        else
          OauthApplication.create!(
            agent_application_fingerprint.except(:deleted_at).merge(is_first_party_agent_app: true)
          )
        end
      end
    end

    def agent_application_fingerprint
      {
        owner: seller,
        owner_type: "User",
        name: AGENT_APP_NAME,
        redirect_uri: AGENT_APP_REDIRECT_URI,
        scopes: AGENT_APP_SCOPES,
        deleted_at: nil,
      }
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
