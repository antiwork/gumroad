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
  include AgentRequestThrottling
  include ActionController::Live
  include AgentConversationPersistence

  before_action { doorkeeper_authorize! :mobile_api }
  before_action :ensure_can_use_agent
  before_action :throttle_agent_requests

  # Match the web stream's heartbeat cadence. Mobile turns have the same silent tool-use stretches,
  # and the periodic refresh prevents the Redis recovery marker from expiring during healthy work.
  STREAM_HEARTBEAT_INTERVAL = 15.seconds
  private_constant :STREAM_HEARTBEAT_INTERVAL

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
    write_lock = Mutex.new
    write_event = ->(payload, event) { write_lock.synchronize { sse.write(payload, event:) } }
    # Commit the stream immediately; the app can start its liveness handling before the first model
    # token, even when the turn opens with silent tool work.
    write_lock.synchronize { response.stream.write(": connected\n\n") }
    heartbeat = nil
    stop_heartbeat = Thread::Queue.new

    begin
      messages = sanitize_messages(params[:messages])
      if messages.empty?
        mark_agent_turn_failed!(client_turn_id)
        write_event.call({ message: "A message is required." }, "error")
        return
      end

      # An unknown/foreign conversation id is surfaced as a stream error (the response status is
      # already committed once we start streaming, so a 404 render isn't possible here).
      begin
        conversation = find_agent_conversation!
      rescue ActiveRecord::RecordNotFound
        mark_agent_turn_failed!(client_turn_id)
        write_event.call({ message: "That conversation could not be found." }, "error")
        return
      end

      # From here the turn is genuinely in flight. Arm the liveness marker (re-armed on every
      # stream write below) so an app whose connection breaks can distinguish "still generating —
      # keep waiting" from "gone".
      mark_agent_turn_in_progress!(client_turn_id)

      heartbeat = Thread.new do
        Rails.application.executor.wrap do
          socket_alive = true
          until stop_heartbeat.pop(timeout: STREAM_HEARTBEAT_INTERVAL.to_f)
            begin
              refresh_agent_turn_in_progress!(client_turn_id)
            rescue => e
              Rails.logger.error("Mobile store agent heartbeat marker refresh failed: #{e.message}")
            end
            next unless socket_alive

            begin
              write_lock.synchronize { response.stream.write(": heartbeat\n\n") }
            rescue IOError, SystemCallError, ActionController::Live::ClientDisconnected
              # Keep refreshing the recovery marker after the socket dies. The request thread can
              # still finish the turn and persist it during a silent tool iteration.
              socket_alive = false
            end
          end
        ensure
          ActiveRecord::Base.connection_pool.release_connection
        end
      end

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
      # trailing SSE writes and the follow-up-suggestions call. A persistence failure still ends
      # cleanly; if it strands a proposed write, reset the confirmation wording that has no stored
      # proposal behind it.
      turn_persisted = false
      assistant_message = nil
      unpersisted_proposal = false
      on_reply_complete = lambda do |turn|
        conversation, assistant_message = persist_agent_turn!(
          conversation,
          new_user_message,
          turn,
          fallback_first_message: messages.last[:content],
          client_turn_id:,
        )
        turn_persisted = true
      rescue => e
        mark_agent_turn_failed!(client_turn_id)
        Rails.logger.error("Mobile store agent turn persistence failed: #{e.full_message}")
        ErrorNotifier.notify(e)
        unpersisted_proposal = replace_unpersisted_proposal_reply!(turn)
      end
      result = ::Ai::StoreAgentService.new(seller:, pundit_user:)
        .respond_streaming(messages: history, on_reply_complete:) do |event, payload|
        # Extend only a marker that is still in progress. on_reply_complete runs before trailing
        # object/proposal/suggestion events and can mark persistence failed; no later event may
        # resurrect that terminal state.
        refresh_agent_turn_in_progress!(client_turn_id)
        # A proposal without a persisted assistant message has no id the confirmation endpoint can
        # claim. finish_stream invokes on_reply_complete first, so suppress the proposal event when
        # that persistence step failed.
        next if event.to_s == "proposed_action" && assistant_message.nil?
        # Suggestions generated from discarded confirmation wording would contradict the
        # replacement reply, so suppress them when no persisted proposal backs this turn.
        next if event.to_s == "suggestions" && unpersisted_proposal

        write_event.call(payload, event)
      end
      # conversation_id is omitted entirely (not null) when creating the conversation itself
      # failed above — this matches the web streaming controller, whose client validates the
      # done frame against a schema where conversation_id is an optional string (a null would
      # fail validation and turn a benign persistence failure into a spurious interrupted-stream
      # recovery). Keeping the mobile frame shape identical means one contract for both clients.
      # A generated proposal is returned only when its assistant message persisted.
      done_payload = {
        reply: result[:reply],
        proposed_action: assistant_message ? result[:proposed_action] : nil,
        objects: result[:objects] || [],
        suggestions: unpersisted_proposal ? [] : result[:suggestions] || [],
      }
      done_payload[:conversation_id] = conversation.external_id if conversation
      done_payload[:proposal_message_id] = assistant_message.external_id if result[:proposed_action] && assistant_message
      write_event.call(done_payload, "done")
    rescue ::Ai::StoreAgentService::Error => e
      mark_agent_turn_failed!(client_turn_id) unless turn_persisted
      write_event.call({ message: e.message }, "error")
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
      write_event.call({ message: "Something went wrong. Please try again." }, "error")
    ensure
      if heartbeat
        stop_heartbeat << true
        heartbeat.join
      end
      sse.close
      ActiveRecord::Base.connection_pool.release_connection
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
      # `throttle!` renders a 429 when the limit is exceeded; Rails halts before_actions once a
      # response is performed.
      throttle_agent_requests_for(seller.id)
    end
end
