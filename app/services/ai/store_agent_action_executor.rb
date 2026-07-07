# frozen_string_literal: true

# Ai::StoreAgentActionExecutor applies a write action that the seller has explicitly confirmed in the
# Agent chat UI. The agent service only ever *proposes* actions; this is the single place a store
# mutation actually happens.
#
# Every confirmed action is a single catalog `api_write`: { endpoint, path_params, params }. The
# executor re-validates the endpoint id against the catalog, confirms it is a write endpoint, and
# REPLAYS the exact same request against the real public v2 API in-process, authenticated with a
# short-lived token minted for this seller (see StoreAgentApiClient). Because it goes through the
# real controller, the endpoint's own Doorkeeper scope check, Pundit/role authorization, and
# validation run again — the executor can never do anything the seller's own API token couldn't, and
# we never trust the proposal blindly:
#   - An unknown or non-write endpoint id is rejected, not guessed.
#   - The token is scoped to THIS seller, so a tampered id can't touch another seller's data; the API
#     resolves every record under the token's resource owner.
#
# Returns { success:, message: } and never raises for expected API failures.
class Ai::StoreAgentActionExecutor
  # The agent now stages every change as a single generic catalog write. We keep the constant name
  # (the controller checks it) but it contains just the one supported proposed-action type.
  SUPPORTED_TYPES = %w[api_write].freeze

  def initialize(seller:, pundit_user:)
    @seller = seller
    @pundit_user = pundit_user
  end

  # @param type [String] must be "api_write"
  # @param params [Hash] { "endpoint" => id, "path_params" => {...}, "params" => {...} }
  # @return [Hash] { success: Boolean, message: String }
  def execute(type:, params:)
    return failure("That action isn't supported.") unless type.to_s == "api_write"

    params = (params || {}).with_indifferent_access
    endpoint = Ai::StoreAgentApiCatalog.find(params[:endpoint])
    return failure("That action isn't supported.") if endpoint.nil? || endpoint.read?

    # Defense in depth: the minted token's scopes are already narrowed to the acting user's role
    # (so a denied endpoint would 403 at the v2 layer), but refuse here too so a tampered/stale
    # proposal for an endpoint outside the user's role never even dispatches a mutation.
    unless endpoint_permitted?(endpoint)
      return failure("You don't have permission to do that.")
    end

    path = endpoint.expand_path(params[:path_params])

    # Defense in depth against a stale or tampered proposal: refuse a body carrying keys the
    # endpoint doesn't declare BEFORE dispatching. The v2 API silently ignores unknown body keys,
    # so such a call would drop the value the seller confirmed (e.g. a price sent as "price_cents")
    # and fail downstream with a confusing internal error. The propose path (StoreAgentService)
    # already rejects these, so a well-formed proposal never hits this.
    body = normalize_body(params[:params])
    unknown_keys_error = endpoint.unknown_param_keys_error(body)
    return failure(unknown_keys_error) if unknown_keys_error

    response = api_client.write(endpoint.method, path, body)

    interpret(endpoint, response)
  rescue ArgumentError => e
    # Missing path param on a tampered/stale action.
    failure(e.message)
  end

  private
    attr_reader :seller, :pundit_user

    # Map the v2 API's { success:, message:, ... } envelope (and HTTP status) to the { success:,
    # message:, object: } shape the chat UI expects. Reuses the API's own validation messages so the
    # seller sees the same error they would hitting the endpoint directly, and surfaces the
    # created/edited object so the chat can render it inline as a card.
    def interpret(endpoint, response)
      status = response["http_status"].to_i
      api_success = response["success"]

      if api_success == true || (api_success.nil? && status.between?(200, 299))
        object = Ai::StoreAgentObjectFormatter.from_response(endpoint, response).first
        success(response["message"].presence || "Done: #{endpoint.summary}", object:)
      elsif status == 401 || status == 403
        failure("You don't have permission to do that.")
      else
        failure(response["message"].presence || response["error"].presence || "That change couldn't be saved.")
      end
    end

    # The proposed params arrive with string keys (they round-tripped through JSON in the proposal).
    # Hand the body to the client as a plain hash; the API normalizes types itself.
    def normalize_body(raw)
      return {} unless raw.is_a?(Hash) || raw.is_a?(ActionController::Parameters)
      raw.to_h
    end

    def api_client
      @_api_client ||= Ai::StoreAgentApiClient.new(seller:, pundit_user:)
    end

    # True if the acting user's role may perform this write. Requires the role's scope AND, for
    # endpoints the dashboard restricts to admins beyond their OAuth scope (admin_only?, e.g. webhook
    # management), an owner/admin actor. Mirrors the token narrowing so a write outside the user's
    # role is refused before any mutation. role_admin_for? is true for the owner too.
    def endpoint_permitted?(endpoint)
      return false if endpoint.admin_only? && !(pundit_user&.user&.role_admin_for?(pundit_user.seller))
      endpoint.scope.blank? || Ai::StoreAgentScopes.permitted_for(pundit_user).include?(endpoint.scope)
    end

    def success(message, object: nil) = { success: true, message:, object: }.compact
    def failure(message) = { success: false, message: }
end
