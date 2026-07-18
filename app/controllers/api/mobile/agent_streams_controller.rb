# frozen_string_literal: true

# Streams one Agent conversation turn as Server-Sent Events for the mobile app, mirroring the web
# streaming endpoint (Api::Internal::AgentMessageStreamsController) so the mobile chat can render
# the reply token-by-token instead of waiting for the whole turn. It lives in its own controller
# (separate from Api::Mobile::AgentController) because ActionController::Live changes the response
# object for EVERY action on the controller it's included in — keeping it isolated means the
# buffered mobile endpoints keep rendering normal JSON responses.
#
# Auth matches the rest of the mobile API: the mobile token (checked by the base controller) plus a
# Doorkeeper bearer for the `mobile_api` scope, with the seller resolved from the token's resource
# owner. The read/propose/confirm safety model lives entirely in Ai::StoreAgentService, exactly as
# on web.
class Api::Mobile::AgentStreamsController < Api::Mobile::BaseController
  include Throttling
  include ActionController::Live
  include AgentConversationPersistence

  before_action { doorkeeper_authorize! :mobile_api }
  before_action :ensure_can_use_agent
  before_action :throttle_agent_requests

  # The mutating agent endpoints share one per-seller budget across web and mobile — the throttle
  # key is seller-scoped, and these constants match the web streaming controller and the buffered
  # mobile controller so no surface gets a bigger allowance than another.
  AGENT_REQUESTS_PER_PERIOD = 30
  AGENT_REQUESTS_PERIOD_WINDOW = 1.hour
  private_constant :AGENT_REQUESTS_PER_PERIOD, :AGENT_REQUESTS_PERIOD_WINDOW

  # POST /api/mobile/agent/messages/stream
  # params: { messages: [{ role:, content: }, ...], conversation_id: <optional external id>,
  #           client_turn_id: <optional client-generated id for this turn> }
  # Each event is `event: <name>` + `data: <json>` + a blank line. Event names: `token` (a chunk of
  # reply text), `reset` (discard text streamed so far — an intermediate tool-use turn's preamble),
  # `objects`, `proposed_action`, `suggestions`, `done` (terminal, carrying the final assembled
  # payload), and `error` (a friendly message; the stream still closes cleanly).
  #
  # Turns are persisted the same way as the buffered endpoints (see AgentConversationPersistence):
  # with a conversation_id the turn appends to that stored conversation and the model replays the
  # server-held transcript; without one a new conversation is created. The `done` event carries the
  # conversation's external id so the app can send it on subsequent turns.
  #
  # `client_turn_id` makes a broken stream recoverable by exact identity, mirroring the web
  # streaming endpoint: the id is stored on the persisted assistant message and a Redis liveness
  # marker tracks the turn while it's generating, so the mobile turn-status endpoint can tell a
  # reconnecting app whether THIS turn persisted, is still generating, or failed.
  def create
    response.headers["Content-Type"] = "text/event-stream"
    response.headers["Cache-Control"] = "no-cache"
    # Disable buffering at the proxy (nginx) layer so events flush to the app as they're written.
    response.headers["X-Accel-Buffering"] = "no"
    sse = ActionController::Live::SSE.new(response.stream)
    client_turn_id = agent_client_turn_id

    begin
      messages = sanitize_messages(params[:messages])
      if messages.empty?
        mark_agent_turn_failed!(client_turn_id)
        sse.write({ message: "A message is required." }, event: "error")
        return
      end

      # An unknown/foreign conversation id is surfaced as a stream error (the response status is
      # already committed once we start streaming, so a 404 render isn't possible here).
      begin
        conversation = find_agent_conversation!
      rescue ActiveRecord::RecordNotFound
        mark_agent_turn_failed!(client_turn_id)
        sse.write({ message: "That conversation could not be found." }, event: "error")
        return
      end

      # From here the turn is genuinely in flight. Arm the liveness marker (re-armed on every
      # stream write below) so an app whose connection breaks can distinguish "still generating —
      # keep waiting" from "gone".
      mark_agent_turn_in_progress!(client_turn_id)

      # The last user entry in the posted history is this turn's new message; when resuming, the
      # earlier entries are replaced by the stored transcript so a stale client can't rewrite
      # history. Nothing is persisted until the service succeeds — a failed turn (the seller sees
      # an error and will retry) must not leave a stray user message that gets silently replayed
      # to the model on the next turn or after a resume.
      new_user_message = messages.reverse.find { |message| message[:role] == "user" }&.dig(:content)
      history =
        if conversation
          agent_conversation_history(conversation) + (new_user_message ? [{ role: "user", content: new_user_message }] : [])
        else
          messages
        end

      # The turn is persisted from on_reply_complete — as soon as the reply is final, before the
      # trailing SSE writes and the follow-up-suggestions call — so a client connection that died
      # mid-stream (the next write raises ClientDisconnected) can't cause a fully generated reply
      # to be dropped unpersisted. Persistence failures are logged but must not break the stream:
      # the only cost is that this turn isn't stored — the failure marker tells a recovering app
      # to stop waiting for it.
      turn_persisted = false
      on_reply_complete = lambda do |turn|
        conversation = persist_agent_turn!(conversation, new_user_message, turn, fallback_first_message: messages.last[:content], client_turn_id:)
        turn_persisted = true
      rescue => e
        mark_agent_turn_failed!(client_turn_id)
        Rails.logger.error("Mobile store agent turn persistence failed: #{e.full_message}")
        ErrorNotifier.notify(e)
      end
      result = ::Ai::StoreAgentService.new(seller:, pundit_user:)
        .respond_streaming(messages: history, on_reply_complete:) do |event, payload|
        # Each write proves the turn is still alive — refresh the marker so long multi-tool turns
        # never read as dead to a recovering app.
        mark_agent_turn_in_progress!(client_turn_id)
        sse.write(payload, event:)
      end
      # conversation_id is omitted entirely (not null) when creating the conversation itself
      # failed above — this matches the web streaming controller, whose client validates the
      # done frame against a schema where conversation_id is an optional string (a null would
      # fail validation and turn a benign persistence failure into a spurious interrupted-stream
      # recovery). Keeping the mobile frame shape identical means one contract for both clients.
      done_payload = {
        reply: result[:reply],
        proposed_action: result[:proposed_action],
        objects: result[:objects] || [],
        suggestions: result[:suggestions] || [],
      }
      done_payload[:conversation_id] = conversation.external_id if conversation
      sse.write(done_payload, event: "done")
    rescue ::Ai::StoreAgentService::Error => e
      mark_agent_turn_failed!(client_turn_id) unless turn_persisted
      sse.write({ message: e.message }, event: "error")
    rescue ActionController::Live::ClientDisconnected
      # The seller backgrounded or closed the app mid-stream. Nothing to surface on the dead
      # socket. If this raised before the turn persisted (a token write failed mid-generation, so
      # the service aborted and the reply will never be stored), record the failure so a
      # recovering app stops waiting; when the turn DID persist first, the stored row is the answer.
      mark_agent_turn_failed!(client_turn_id) unless turn_persisted
    rescue => e
      mark_agent_turn_failed!(client_turn_id) unless turn_persisted
      Rails.logger.error("Mobile store agent stream failed: #{e.full_message}")
      ErrorNotifier.notify(e)
      sse.write({ message: "Something went wrong. Please try again." }, event: "error")
    ensure
      sse.close
    end
  end

  private
    def seller
      current_resource_owner
    end

    # AgentConversationPersistence scopes every lookup/write to `current_seller`; on mobile the
    # authenticated bearer's resource owner IS the seller, so alias one to the other.
    def current_seller
      seller
    end

    # The mobile bearer maps to a single seller (no team-member impersonation here), so the user and
    # seller in the SellerContext are the same account — exactly what the service expects.
    def pundit_user
      @_pundit_user ||= SellerContext.new(user: seller, seller:)
    end

    def ensure_can_use_agent
      return if UserPolicy.new(pundit_user, seller).use_store_agent?

      render json: { success: false, error: "You don't have access to the store agent." }, status: :forbidden
    end

    def throttle_agent_requests
      key = RedisKey.agent_request_throttle(seller.id)
      # `throttle!` renders a 429 when the limit is exceeded; Rails halts before_actions once a
      # response is performed.
      throttle!(key:, limit: AGENT_REQUESTS_PER_PERIOD, period: AGENT_REQUESTS_PERIOD_WINDOW)
    end
end
