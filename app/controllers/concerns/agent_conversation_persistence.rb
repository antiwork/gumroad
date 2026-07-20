# frozen_string_literal: true

# Shared persistence for the web store Agent endpoints (buffered + streaming). The chat history
# used to live only in the browser's React state, so a refresh lost it; these helpers store each
# turn server-side (like OpenAI/Claude persist chats) so the client can resume a conversation.
#
# The client optionally sends `conversation_id` (an AiConversation external id). When present we
# replay the SERVER-held transcript to the model instead of trusting whatever history the client
# posted — the stored conversation is the source of truth. When absent we start a new conversation
# titled after the opening message. Lookups are scoped to current_seller, so one seller can never
# read or append to another seller's conversation (a foreign id behaves like a missing one).
module AgentConversationPersistence
  extend ActiveSupport::Concern

  # Conversations grow one turn at a time forever (there's no "end" to a chat), so both the
  # transcript replayed to the model and the hydration payload need a ceiling. 100 messages
  # (~50 turns) comfortably covers a long working session while capping the per-turn token cost
  # and keeping the resume response a bounded size; older messages are still stored, just no
  # longer replayed or hydrated.
  HISTORY_MAX_MESSAGES = 100

  # The streaming clients tag each turn with a self-generated id (a UUID) so that, when the SSE
  # connection breaks mid-turn, they can ask "did MY turn persist?" by exact id instead of
  # guessing from the seller's latest conversation (which another tab or device can change at any
  # moment). The id is opaque to the server — it only has to be unique per turn — but its shape is
  # validated so arbitrary client strings don't end up in Redis keys or stored metadata.
  CLIENT_TURN_ID_FORMAT = /\A[0-9a-fA-F-]{1,64}\z/
  # TTL of the Redis "this turn is being generated right now" marker. The marker is re-armed on
  # every stream write, and the model client tolerates up to 120 seconds of silence between chunks
  # (Ai::StoreAgentService::REQUEST_TIMEOUT_IN_SECONDS) — so the TTL must comfortably outlast that
  # silence plus the trailing persistence + follow-up-suggestions work. If the marker expires it
  # means the server stopped working on the turn without recording an outcome (the process died),
  # and a recovering client should stop waiting.
  AGENT_TURN_IN_PROGRESS_TTL = 180.seconds
  # TTL of the Redis "this turn failed / will never persist" marker. Only needs to outlive a
  # recovering client's polling window; it exists so the client can stop waiting immediately
  # instead of polling an in-progress marker down to expiry.
  AGENT_TURN_FAILED_TTL = 10.minutes
  # Recovery lookups only ever happen minutes after the turn was sent, so the by-id search is
  # bounded to recent messages — this keeps the metadata scan from walking a seller's entire
  # chat history.
  AGENT_TURN_LOOKUP_WINDOW = 1.hour

  private
    # Returns the seller's conversation for params[:conversation_id], or nil when the param is
    # absent. A present-but-unknown id (including another seller's conversation) raises
    # ActiveRecord::RecordNotFound so callers can render a 404 rather than silently starting a
    # fresh conversation with someone else's id.
    def find_agent_conversation!
      external_id = params[:conversation_id].to_s
      return nil if external_id.blank?

      current_seller.ai_conversations.alive.find_by_external_id(external_id) ||
        raise(ActiveRecord::RecordNotFound)
    end

    def create_agent_conversation!(first_user_message)
      current_seller.ai_conversations.create!(title: AiConversation.title_from(first_user_message))
    end

    # Cleans the client-posted chat history down to what the agent actually accepts: an array of
    # { role:, content: } hashes where the role is "user" or "assistant" and the content is
    # non-blank. Everything else — non-array payloads, non-hash entries, unknown roles (a client
    # can't inject "system" messages), blank messages — is dropped rather than rejected, so one
    # malformed entry doesn't fail the whole request. Shared by every agent endpoint (web and
    # mobile, buffered and streaming) so a change to message validation lands in one place.
    def sanitize_messages(raw)
      return [] unless raw.is_a?(ActionController::Parameters) || raw.is_a?(Array)

      Array(raw).filter_map do |message|
        message = message.respond_to?(:to_unsafe_h) ? message.to_unsafe_h : message
        next unless message.is_a?(Hash)

        role = message[:role] || message["role"]
        content = (message[:content] || message["content"]).to_s
        next unless %w[user assistant].include?(role)
        next if content.strip.blank?

        { role:, content: }
      end
    end

    # Persists one full turn (creating the conversation when needed) atomically. Without the
    # transaction, a failure between the user-message insert and the assistant-message insert would
    # strand a half-written turn: `latest` would hydrate a user message with no reply, and a resumed
    # turn would silently replay that stray message to the model. Returns the conversation so
    # callers can hand its external id back to the client. `client_turn_id` (streaming turns only)
    # is stored on the assistant message so a client whose stream broke can find this exact turn.
    def persist_agent_turn!(conversation, new_user_message, result, fallback_first_message:, client_turn_id: nil)
      AiConversation.transaction do
        conversation ||= create_agent_conversation!(new_user_message || fallback_first_message)
        record_agent_user_message!(conversation, new_user_message) if new_user_message.present?
        record_agent_assistant_message!(conversation, result, client_turn_id:)
        conversation
      end
    end

    # The plain role/content transcript to send to the model — rebuilt from the stored rows so a
    # tampered or stale client-side history can't rewrite what the agent believes was said. Only
    # the most recent HISTORY_MAX_MESSAGES are replayed: without a cap, every turn of a long-lived
    # conversation would resend the entire transcript to the LLM (O(n²) token cost over the
    # conversation's life) — `last` keeps the newest rows while preserving chronological order.
    def agent_conversation_history(conversation)
      conversation.ai_messages.last(HISTORY_MAX_MESSAGES).map { |message| { role: message.role, content: message.content } }
    end

    def record_agent_user_message!(conversation, content)
      conversation.ai_messages.create!(role: "user", content:)
    end

    # Persists the assistant's turn. The proposed action and looked-up objects ride along in
    # `metadata` so a reloaded conversation re-renders its confirmation card / object cards.
    # `client_turn_id` (when the turn came from a streaming endpoint) also rides along so the turn
    # is findable by the exact id the client generated, independent of which conversation is
    # currently the seller's latest.
    def record_agent_assistant_message!(conversation, result, client_turn_id: nil)
      metadata = {
        proposed_action: result[:proposed_action],
        objects: result[:objects].presence,
        client_turn_id:,
      }.compact
      conversation.ai_messages.create!(role: "assistant", content: result[:reply].to_s, metadata: metadata.presence)
    end

    # The client-generated id tagging this streamed turn, or nil when absent or malformed. The
    # format check keeps arbitrary client strings out of Redis keys and stored metadata; a
    # malformed id just means the turn isn't recoverable by id, never an error.
    def agent_client_turn_id
      turn_id = params[:client_turn_id].to_s
      turn_id if turn_id.match?(CLIENT_TURN_ID_FORMAT)
    end

    # ── Turn liveness markers ─────────────────────────────────────────────────────────────────
    # A client whose SSE stream broke can't tell "the server is still generating my turn" apart
    # from "my turn is gone" by looking at stored rows alone — the turn only becomes a row once
    # the reply completes. These Redis markers fill that gap: the streaming endpoints arm
    # `in_progress` when the turn starts and re-arm it on every stream write (the marker outlives
    # the model's max 120s silence between chunks), and record `failed` when the turn aborts or
    # can't be persisted. The turn-status endpoint reads them to tell a recovering client whether
    # to keep waiting.

    def mark_agent_turn_in_progress!(client_turn_id)
      return if client_turn_id.blank?

      $redis.set(RedisKey.agent_turn_status(current_seller.id, client_turn_id), "in_progress", ex: AGENT_TURN_IN_PROGRESS_TTL.to_i)
    end

    def mark_agent_turn_failed!(client_turn_id)
      return if client_turn_id.blank?

      $redis.set(RedisKey.agent_turn_status(current_seller.id, client_turn_id), "failed", ex: AGENT_TURN_FAILED_TTL.to_i)
    end

    def agent_turn_marker(client_turn_id)
      return nil if client_turn_id.blank?

      $redis.get(RedisKey.agent_turn_status(current_seller.id, client_turn_id))
    end

    # The seller's persisted assistant message carrying this client turn id, or nil. Scoped to the
    # seller (a foreign turn id can never read another seller's turn) and to recent messages —
    # recovery happens minutes after the turn, so the window keeps the metadata scan bounded.
    def find_agent_turn_message(client_turn_id)
      return nil if client_turn_id.blank?

      AiMessage
        .joins(:ai_conversation)
        .where(ai_conversations: { seller_id: current_seller.id, deleted_at: nil })
        .where("ai_messages.created_at >= ?", AGENT_TURN_LOOKUP_WINDOW.ago)
        .role_assistant
        .where("ai_messages.metadata->>'$.client_turn_id' = ?", client_turn_id)
        .order(created_at: :desc, id: :desc)
        .first
    end

    # After a seller confirms a proposed change, mark the proposing assistant message as applied
    # (and attach the resulting object) so history shows the collapsed "Applied" card instead of a
    # still-confirmable one. Multiple proposals can be pending in one chat (the seller can scroll
    # back and confirm an earlier one), so identify the confirmed proposal by matching the executed
    # payload (type + params) against the stored one — never by assuming it's the newest.
    def record_agent_action_applied!(conversation, result, type:, action_params:)
      executed = normalize_action_payload("type" => type, "params" => action_params)
      message = conversation.ai_messages
        .role_assistant
        .select(:id, :metadata, :created_at)
        .reorder(created_at: :desc, id: :desc)
        .detect do |candidate|
          proposal = candidate.metadata&.dig("proposed_action")
          next false if proposal.blank? || candidate.metadata["action_status"].present?

          normalize_action_payload("type" => proposal["type"], "params" => proposal["params"]) == executed
        end
      return if message.nil?

      metadata = message.metadata.merge("action_status" => "applied")
      # Mirror the live UI: once applied, the created/edited object replaces the turn's lookup
      # objects as the thing worth showing.
      metadata["objects"] = [result[:object]] if result[:object].present?
      # The candidates above were loaded with a narrow `select` (no MEDIUMTEXT content), and saving
      # a partially-loaded record raises MissingAttributeError — so re-fetch the full row before
      # saving. Use `update!` (not `update_column`) so the `belongs_to :ai_conversation, touch: true`
      # callback bumps the conversation's `updated_at`; without that, confirming a proposal wouldn't
      # count as activity and `GET /internal/agent/conversations/latest` could resume a different,
      # more recently active conversation after the seller refreshes.
      conversation.ai_messages.find(message.id).update!(metadata:)
    end

    # The shape the chat clients (AgentChat.tsx on web, the Agent tab on mobile) hydrate a resumed
    # conversation from: the plain transcript plus each turn's persisted extras (proposed-action
    # card, object cards, applied/dismissed status) so history re-renders exactly as it did live.
    # Shared here so web and mobile can never drift apart on the resume payload.
    # Hydration is capped at the same window the model replays (HISTORY_MAX_MESSAGES) so a very
    # long conversation doesn't produce a multi-megabyte resume payload — and so what the seller
    # sees matches what the model will be shown on the next turn.
    def agent_conversation_props(conversation)
      {
        id: conversation.external_id,
        title: conversation.title,
        messages: conversation.ai_messages.last(HISTORY_MAX_MESSAGES).map { |message| agent_message_props(message) },
      }
    end

    # One message in the shape the chat clients hydrate from — shared by the conversation resume
    # payload above and the turn-status endpoint (which returns a single recovered turn), so the
    # two can't drift on how persisted extras come back to life.
    def agent_message_props(message)
      metadata = message.metadata || {}
      {
        role: message.role,
        content: message.content,
        proposed_action: metadata["proposed_action"],
        objects: metadata["objects"],
        action_status: metadata["action_status"],
      }.compact
    end

    # Recursively string-keys hashes and stringifies scalar leaves so the executed request params
    # (which arrive with string values under form encoding, or native types under JSON) compare
    # equal to the stored proposal payload regardless of transport/serialization differences.
    def normalize_action_payload(value)
      case value
      when Hash
        value.each_with_object({}) { |(k, v), out| out[k.to_s] = normalize_action_payload(v) }
      when Array
        value.map { |v| normalize_action_payload(v) }
      when nil
        nil
      else
        value.to_s
      end
    end
end
