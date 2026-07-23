# frozen_string_literal: true

# Streams one Agent conversation turn as Server-Sent Events, so the reply renders token-by-token and
# ends with a few follow-up suggestions to keep the conversation going. This lives in its own
# controller (separate from Api::Internal::AgentMessagesController) because ActionController::Live
# changes the response object for EVERY action on the controller it's included in — keeping it
# isolated means the buffered messages/actions endpoints render normal JSON responses.
#
# It shares the exact same guards as the buffered endpoints — authentication, the
# UserPolicy#use_store_agent? authorization, and the per-seller throttle — so the streaming path is
# no less protected. The read/propose/confirm safety model lives entirely in Ai::StoreAgentService.
class Api::Internal::AgentMessageStreamsController < Api::Internal::BaseController
  include Throttling
  include ActionController::Live
  include AgentConversationPersistence

  before_action :authenticate_user!
  before_action :authorize_store_agent
  before_action :throttle_agent_requests
  after_action :verify_authorized

  AGENT_REQUESTS_PER_PERIOD = 30
  AGENT_REQUESTS_PERIOD_WINDOW = 1.hour
  private_constant :AGENT_REQUESTS_PER_PERIOD, :AGENT_REQUESTS_PERIOD_WINDOW

  # How often to write an SSE keepalive comment while the turn is being generated. Real events can
  # be minutes apart: tool-use iterations (up to Ai::StoreAgentService::MAX_TOOL_ITERATIONS of
  # them) write nothing to the stream — the model's tool JSON and the tool execution all happen
  # server-side — and the model client tolerates up to 120 seconds of silence between chunks. Each
  # heartbeat does two jobs: the comment bytes tell the client the connection is alive (its stall
  # detector treats a long-silent stream as a dead connection and gives up on it), and the
  # in-progress marker refresh keeps a recovering client told the truth. 15s leaves a wide margin
  # against both the client's stall threshold and the marker's TTL.
  STREAM_HEARTBEAT_INTERVAL = 15.seconds
  private_constant :STREAM_HEARTBEAT_INTERVAL

  # POST /internal/agent/messages/stream
  # params: { messages: [{ role:, content: }, ...], conversation_id: <optional external id>,
  #           client_turn_id: <optional client-generated id for this turn> }
  # Each event is `event: <name>` + `data: <json>` + a blank line. Event names: `token` (a chunk of
  # reply text), `objects`, `proposed_action`, `suggestions`, `done` (terminal, carrying the final
  # assembled payload), and `error` (a friendly message; the stream still closes cleanly).
  #
  # Turns are persisted the same way as the buffered endpoint (see AgentConversationPersistence):
  # with a conversation_id the turn appends to that stored conversation and the model replays the
  # server-held transcript; without one a new conversation is created. The `done` event carries the
  # conversation's external id so the client can send it on subsequent turns.
  #
  # `client_turn_id` makes a broken stream recoverable by exact identity: the id is stored on the
  # persisted assistant message and a Redis liveness marker tracks the turn while it's generating,
  # so the turn-status endpoint (agent_turns#turn_status) can tell a reconnecting client whether
  # THIS turn persisted, is still being generated, or failed — no guessing from "latest".
  def create
    response.headers["Content-Type"] = "text/event-stream"
    response.headers["Cache-Control"] = "no-cache"
    # Disable buffering at the proxy (nginx) layer so events flush to the browser as they're written.
    response.headers["X-Accel-Buffering"] = "no"
    sse = ActionController::Live::SSE.new(response.stream)
    client_turn_id = agent_client_turn_id
    # The heartbeat thread below writes to the stream alongside this request thread, and SSE
    # frames must never interleave mid-frame — every stream write goes through this lock.
    write_lock = Mutex.new
    write_event = ->(payload, event) { write_lock.synchronize { sse.write(payload, event:) } }
    # Commit the response headers right away with an SSE comment (":"-prefixed lines are ignored
    # by SSE parsers). ActionController::Live holds headers back until the first stream write, and
    # on a turn that opens with silent tool work the first real event can be minutes away — until
    # the client sees the response begin it can't tell a working turn from a dead connection.
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

      # From here the turn is genuinely in flight. Arm the liveness marker so a client whose
      # connection breaks can distinguish "still generating — keep waiting" from "gone". It's
      # re-armed on every stream write below and by the heartbeat, keeping it alive across the
      # turn's silent stretches (tool-use iterations write nothing to the stream, and the model
      # client tolerates up to 120s between chunks).
      mark_agent_turn_in_progress!(client_turn_id)

      # Keepalive writer for the silent stretches. Queue#pop with a timeout doubles as an
      # interruptible sleep: it returns nil each interval until the ensure below pushes the stop
      # signal, so shutdown is immediate rather than waiting out a sleep.
      heartbeat = Thread.new do
        socket_alive = true
        until stop_heartbeat.pop(timeout: STREAM_HEARTBEAT_INTERVAL.to_f)
          # The marker refresh must outlive the socket: the request thread keeps generating after
          # a client disconnect (silent tool iterations write nothing, so nothing raises) and can
          # legitimately persist the turn minutes later — and a recovering client is told
          # "in_progress" only while this marker lives. So refresh unconditionally, and only skip
          # the socket write once the client is known to be gone. A Redis blip must not kill the
          # heartbeat either — the socket comment below is what keeps the client's stall detector
          # fed — so refresh failures are logged and retried on the next tick.
          begin
            refresh_agent_turn_in_progress!(client_turn_id)
          rescue => e
            Rails.logger.error("Store agent heartbeat marker refresh failed: #{e.message}")
          end
          next unless socket_alive

          begin
            write_lock.synchronize { response.stream.write(": heartbeat\n\n") }
          rescue IOError, SystemCallError, ActionController::Live::ClientDisconnected
            # The client is gone — stop writing to the dead socket, but keep the marker refreshes
            # going. The request thread's own next write surfaces the disconnect through its
            # existing handling. SystemCallError is included because a dead socket can surface as
            # Errno::EPIPE / Errno::ECONNRESET rather than the wrapped ClientDisconnected, and an
            # uncaught error here would kill the whole heartbeat thread, refreshes included.
            socket_alive = false
          end
        end
      end

      # The last user entry in the posted history is this turn's new message; when resuming, the
      # earlier entries are replaced by the stored transcript so a stale client can't rewrite
      # history. Nothing is persisted until the service succeeds — a failed turn (the seller sees
      # an error and will retry) must not leave a stray user message that gets silently replayed
      # to the model on the next turn or after a refresh.
      new_user_message = messages.reverse.find { |message| message[:role] == "user" }&.dig(:content)
      history =
        if conversation
          agent_conversation_history(conversation) + (new_user_message ? [{ role: "user", content: new_user_message }] : [])
        else
          messages
        end

      # The turn is persisted from on_reply_complete — the moment the reply is final, BEFORE the
      # trailing SSE writes and the extra follow-up-suggestions LLM call. Two reasons: if the
      # client's connection died mid-stream, the next socket write raises ClientDisconnected and
      # would abandon a fully generated reply unpersisted; and persisting early means a client
      # that reconciles a broken stream against the stored conversation finds the turn right away
      # instead of racing the suggestions call.
      #
      # Persistence itself must not mask a reply the seller has already watched stream in. If
      # recording the turn fails (e.g. a DB hiccup after a long LLM call), log + report it but let
      # the stream finish — dropping `done` would leave the client without a conversation id, so
      # the next turn would silently start a brand-new conversation. The only cost of a
      # persistence failure is that this turn isn't stored — the failure marker tells a
      # recovering client to stop waiting for it.
      turn_persisted = false
      on_reply_complete = lambda do |turn|
        conversation = persist_agent_turn!(conversation, new_user_message, turn, fallback_first_message: messages.last[:content], client_turn_id:)
        turn_persisted = true
      rescue => e
        mark_agent_turn_failed!(client_turn_id)
        Rails.logger.error("Store agent turn persistence failed: #{e.full_message}")
        ErrorNotifier.notify(e)
      end
      result = ::Ai::StoreAgentService.new(seller: current_seller, pundit_user:)
        .respond_streaming(messages: history, on_reply_complete:) do |event, payload|
        # Each write proves the turn is still alive — refresh the marker so long multi-tool turns
        # never read as dead to a recovering client.
        mark_agent_turn_in_progress!(client_turn_id)
        write_event.call(payload, event)
      end
      # conversation_id is omitted entirely (not null) when creating the conversation itself
      # failed above — the client validates this frame against a schema where conversation_id
      # is an optional string, so a null would fail validation and turn a benign persistence
      # failure into a spurious interrupted-stream recovery. proposed_action stays present even
      # when nil: the client schema requires it (nullable, not optional).
      done_payload = {
        reply: result[:reply],
        proposed_action: result[:proposed_action],
        objects: result[:objects] || [],
        suggestions: result[:suggestions] || [],
      }
      done_payload[:conversation_id] = conversation.external_id if conversation
      write_event.call(done_payload, "done")
    rescue ::Ai::StoreAgentService::Error => e
      mark_agent_turn_failed!(client_turn_id) unless turn_persisted
      write_event.call({ message: e.message }, "error")
    rescue ActionController::Live::ClientDisconnected
      # The seller navigated away or closed the tab mid-stream. Nothing to surface on the dead
      # socket. If this raised before the turn persisted (a token write failed mid-generation, so
      # the service aborted and the reply will never be stored), record the failure so a
      # recovering client stops waiting. When the turn DID persist first, leave the stored row as
      # the answer — no marker needed.
      mark_agent_turn_failed!(client_turn_id) unless turn_persisted
    rescue => e
      mark_agent_turn_failed!(client_turn_id) unless turn_persisted
      Rails.logger.error("Store agent stream failed: #{e.full_message}")
      ErrorNotifier.notify(e)
      write_event.call({ message: "Something went wrong. Please try again." }, "error")
    ensure
      # Stop the heartbeat before closing the stream so it can't write to (or refresh the marker
      # for) a turn that has already ended. The failure paths above run first, so a "failed"
      # marker is in place before the heartbeat's last value check — and its refresh only extends
      # markers still reading "in_progress", never a recorded outcome.
      if heartbeat
        stop_heartbeat << true
        heartbeat.join
      end
      sse.close
    end
  end

  private
    def authorize_store_agent
      authorize current_seller, :use_store_agent?
    end

    def throttle_agent_requests
      return unless current_user

      key = RedisKey.agent_request_throttle(current_seller.id)
      # `throttle!` renders a 429 when the limit is exceeded; Rails halts before_actions once a
      # response is performed.
      throttle!(key:, limit: AGENT_REQUESTS_PER_PERIOD, period: AGENT_REQUESTS_PERIOD_WINDOW)
    end
end
