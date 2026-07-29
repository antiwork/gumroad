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
  # every stream write and by the streaming controller's periodic heartbeat (which covers the long
  # silent stretches: tool-use iterations write nothing to the stream, and the model client
  # tolerates up to 120 seconds of silence between chunks —
  # Ai::StoreAgentService::REQUEST_TIMEOUT_IN_SECONDS). The TTL must comfortably outlast the
  # heartbeat interval. If the marker expires it means the server stopped working on the turn
  # without recording an outcome (the process died), and a recovering client should stop waiting.
  AGENT_TURN_IN_PROGRESS_TTL = 180.seconds
  # TTL of the Redis "this turn failed / will never persist" marker. Only needs to outlive a
  # recovering client's polling window; it exists so the client can stop waiting immediately
  # instead of polling an in-progress marker down to expiry.
  AGENT_TURN_FAILED_TTL = 10.minutes
  # Recovery lookups only ever happen minutes after the turn was sent, so the by-id search is
  # bounded to recent messages — this keeps the metadata scan from walking a seller's entire
  # chat history.
  AGENT_TURN_LOOKUP_WINDOW = 1.hour
  # Keep deploy-skew matching bounded. If the scope exceeds this cap, reject the legacy request
  # instead of truncating away an older completed duplicate and retargeting a newer proposal.
  LEGACY_ACTION_LOOKUP_LIMIT = 1000
  FORM_DECIMAL_NUMBER_PATTERN = /\A-?(?:0|[1-9]\d*)(?:\.\d+)?\z/
  ACTION_NUMBER_INPUT_MAX_BYTES = 128
  ACTION_NUMBER_MAX_EXPONENT = 1000
  ACTION_STATUS_EXECUTING = "executing"
  ACTION_STATUS_APPLIED = "applied"
  ACTION_STATUS_UNKNOWN = "unknown"
  # Confirmation replays run inside the Rack request that received the seller's click. Rack's
  # 120-second timer starts before authentication, proposal lookup, and this claim, so a claim
  # that itself reaches 120 seconds belongs to a request already beyond that hard horizon. This
  # also lets the web poller's last read at about 127.5 seconds persist the terminal result.
  ACTION_EXECUTION_ABANDONED_AFTER = 2.minutes
  ACTION_ALREADY_CONFIRMED_MESSAGE = "That proposal has already been confirmed."
  ACTION_CONFIRMATION_RETRY_MESSAGE = "That proposal is pending and can be confirmed again."
  ACTION_CONFIRMATION_MISMATCH_MESSAGE = "That confirmation doesn't match a pending proposal. Ask the agent to prepare it again."
  UNPERSISTED_PROPOSAL_REPLY = "I couldn't save that proposed change, so there is nothing to confirm. Please ask me to prepare it again."
  UNRESOLVED_MOBILE_ACTION_REPLY = "The outcome of this change is not available in this app. Check your store before asking the agent to try again."
  MISSING_PROPOSAL_MESSAGE_ID_NOTICE = "Store agent confirmation omitted proposal message id"
  ACTION_CLAIM_RELEASE_FAILED_NOTICE = "Store agent action claim could not be released"

  private_constant :LEGACY_ACTION_LOOKUP_LIMIT,
                   :FORM_DECIMAL_NUMBER_PATTERN,
                   :ACTION_NUMBER_INPUT_MAX_BYTES,
                   :ACTION_NUMBER_MAX_EXPONENT,
                   :ACTION_STATUS_EXECUTING,
                   :ACTION_STATUS_APPLIED,
                   :ACTION_STATUS_UNKNOWN,
                   :ACTION_EXECUTION_ABANDONED_AFTER,
                   :ACTION_ALREADY_CONFIRMED_MESSAGE,
                   :ACTION_CONFIRMATION_RETRY_MESSAGE,
                   :ACTION_CONFIRMATION_MISMATCH_MESSAGE,
                   :UNPERSISTED_PROPOSAL_REPLY,
                   :UNRESOLVED_MOBILE_ACTION_REPLY,
                   :MISSING_PROPOSAL_MESSAGE_ID_NOTICE,
                   :ACTION_CLAIM_RELEASE_FAILED_NOTICE

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
    # turn would silently replay that stray message to the model. Returns both the conversation and
    # assistant message so callers can give clients the persisted proposal's exact id. `client_turn_id`
    # (streaming turns only) is stored on the assistant message so a client whose stream broke can
    # find this exact turn.
    def persist_agent_turn!(conversation, new_user_message, result, fallback_first_message:, client_turn_id: nil)
      AiConversation.transaction do
        conversation ||= create_agent_conversation!(new_user_message || fallback_first_message)
        record_agent_user_message!(conversation, new_user_message) if new_user_message.present?
        assistant_message = record_agent_assistant_message!(conversation, result, client_turn_id:)
        [conversation, assistant_message]
      end
    end

    # A generated proposal cannot be confirmed unless its assistant message was stored.
    def replace_unpersisted_proposal_reply!(result)
      return false if result[:proposed_action].blank?

      result[:reply] = UNPERSISTED_PROPOSAL_REPLY
      true
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

    # Re-arm the in-progress marker's TTL without changing what it says. Used by the streaming
    # controller's heartbeat, which fires on a timer and can race the failure paths — a plain SET
    # there could resurrect "in_progress" moments after the turn was marked failed, leaving a
    # recovering client polling a verdict the server already reached. Only an existing
    # "in_progress" marker is extended; a "failed" marker (or an already-expired one) is left
    # untouched. The check and the extend run as one Lua script because they race the request
    # thread: done separately, a "failed" written between them would get the (much shorter)
    # in-progress TTL applied to it, cutting the failure marker's lifetime.
    AGENT_TURN_REFRESH_IF_IN_PROGRESS_SCRIPT = <<~LUA.squish
      if redis.call("get", KEYS[1]) == ARGV[1] then
        return redis.call("expire", KEYS[1], ARGV[2])
      else
        return 0
      end
    LUA

    def refresh_agent_turn_in_progress!(client_turn_id)
      return if client_turn_id.blank?

      key = RedisKey.agent_turn_status(current_seller.id, client_turn_id)
      $redis.eval(AGENT_TURN_REFRESH_IF_IN_PROGRESS_SCRIPT, keys: [key], argv: ["in_progress", AGENT_TURN_IN_PROGRESS_TTL.to_i])
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

    # Claims the exact persisted proposal before its API request is replayed. The JSON update is a
    # compare-and-set: only a proposal with no action_status can move to "executing", so concurrent
    # confirmations and later replays cannot both dispatch. The update commits before the HTTP call;
    # holding a database transaction open across that call would tie up locks and connections.
    #
    # Native app releases cannot be deployed atomically with the server, and an already-open web tab
    # may still use the old request shape. Missing ids are accepted only when the bounded full
    # scope contains exactly one payload match. A scope over the cap is rejected rather than
    # truncating away an older completed duplicate and retargeting a newer proposal.
    def claim_agent_action(conversation, proposal_message_id:, type:, action_params:)
      executed = { "type" => type, "params" => action_params }
      proposal_scope =
        if conversation
          conversation.ai_messages.role_assistant
        else
          AiMessage.role_assistant
            .joins(:ai_conversation)
            .merge(current_seller.ai_conversations.alive)
        end
      message =
        if proposal_message_id.present?
          proposal_scope.find_by(id: AiMessage.from_external_id(proposal_message_id))
        else
          log_missing_proposal_message_id
          candidates = proposal_scope
            .select(:id, :metadata, :created_at)
            .reorder(created_at: :desc, id: :desc)
            .limit(LEGACY_ACTION_LOOKUP_LIMIT + 1)
            .to_a
          matching_messages =
            if candidates.size > LEGACY_ACTION_LOOKUP_LIMIT
              []
            else
              candidates.select do |candidate|
                candidate.metadata&.dig("proposed_action").present? &&
                  action_payload_matches?(candidate, executed)
              end
            end
          proposal_scope.find(matching_messages.first.id) if matching_messages.one?
        end

      return [nil, ACTION_CONFIRMATION_MISMATCH_MESSAGE, nil] if message.nil?
      return [nil, ACTION_CONFIRMATION_MISMATCH_MESSAGE, nil] unless action_payload_matches?(message, executed)

      existing_status = message.metadata["action_status"]
      if existing_status.present?
        existing_status = reconcile_stale_agent_action!(message)
        return [nil, ACTION_ALREADY_CONFIRMED_MESSAGE, existing_status] if existing_status.present?

        # A concurrent request can reject before dispatch and safely release its claim after this
        # request loaded "executing". The database is pending again, so continue to the claim
        # instead of telling the client an action is still running.
        message.reload
      end

      2.times do
        claimed = nil
        AiMessage.transaction do
          claimed = compare_and_set_agent_action_claim(message)
          if claimed == 1
            # The compare-and-set bypasses AiMessage's `touch: true` association callback. Claiming a
            # proposal is conversation activity even when the nested request later has an
            # indeterminate result, so keep this chat ahead of older ones in resume-latest ordering.
            # Keep these two local writes atomic: if the touch fails, the pre-dispatch claim rolls
            # back and stays safe to retry. The nested HTTP replay starts only after this transaction.
            (conversation || message.ai_conversation).touch
          end
        end
        return [message, nil, nil] if claimed == 1

        message.reload
        existing_status = reconcile_stale_agent_action!(message)
        return [nil, ACTION_ALREADY_CONFIRMED_MESSAGE, existing_status] if existing_status.present?
      end

      # Two consecutive claims can lose to requests that both release safely before dispatch. Do
      # not spin or invent an executing state: the persisted proposal is pending and the client may
      # retry. A later claim still has to win the same database compare-and-set before dispatch.
      [nil, ACTION_CONFIRMATION_RETRY_MESSAGE, nil, true]
    end

    def compare_and_set_agent_action_claim(message)
      AiMessage
        .where(id: message.id)
        .where("JSON_EXTRACT(metadata, '$.action_status') IS NULL")
        .update_all(
          [
            "metadata = JSON_SET(metadata, '$.action_status', ?), updated_at = CURRENT_TIMESTAMP(6)",
            ACTION_STATUS_EXECUTING,
          ],
        )
    end

    def agent_action_confirmation_error(message, action_status, retryable: false)
      result = { success: false, message: }
      if [ACTION_STATUS_EXECUTING, ACTION_STATUS_APPLIED, ACTION_STATUS_UNKNOWN].include?(action_status)
        result[:action_status] = action_status
      end
      result[:retryable] = true if retryable
      result
    end

    # A rejected API replay made no store change, so remove only this request's executing claim and
    # let the seller retry the same persisted proposal. A failed compare-and-set means the audit row
    # moved unexpectedly; report it rather than deleting a newer status.
    def release_agent_action_claim!(message)
      released = AiMessage
        .where(id: message.id)
        .where("JSON_UNQUOTE(JSON_EXTRACT(metadata, '$.action_status')) = ?", ACTION_STATUS_EXECUTING)
        .update_all("metadata = JSON_REMOVE(metadata, '$.action_status'), updated_at = CURRENT_TIMESTAMP(6)")
      return true if released == 1

      Rails.logger.error(ACTION_CLAIM_RELEASE_FAILED_NOTICE)
      ErrorNotifier.notify(
        ACTION_CLAIM_RELEASE_FAILED_NOTICE,
        exclude_request_context: true,
        ai_message_id: message.id,
      )
      false
    end

    # Return the persisted status plus whether the proposal is now safe to retry.
    def release_retry_safe_agent_action_claim!(message)
      return [nil, true] if release_agent_action_claim!(message)

      action_status = message.reload.metadata["action_status"].presence
      [action_status, action_status.nil?]
    end

    # A response or exception after nested dispatch cannot prove whether the endpoint mutated.
    # Move the transient execution claim to a stable, non-retryable state so concurrent clients
    # can stop polling without pretending work is still active.
    def record_agent_action_outcome_unknown!(message, stale_after: nil, touch_conversation: true)
      changed = nil
      AiMessage.transaction do
        scope = AiMessage
          .where(id: message.id)
          .where("JSON_UNQUOTE(JSON_EXTRACT(metadata, '$.action_status')) = ?", ACTION_STATUS_EXECUTING)
        if stale_after
          scope = scope.where(
            "updated_at <= DATE_SUB(CURRENT_TIMESTAMP(6), INTERVAL ? SECOND)",
            stale_after.to_i,
          )
        end
        changed = scope.update_all(
          [
            "metadata = JSON_SET(metadata, '$.action_status', ?), updated_at = CURRENT_TIMESTAMP(6)",
            ACTION_STATUS_UNKNOWN,
          ],
        )
        message.ai_conversation.touch if changed == 1 && touch_conversation
      end
      return ACTION_STATUS_UNKNOWN if changed == 1

      message.reload.metadata["action_status"].presence
    rescue => e
      # The one-shot executing claim is already safe if this audit transition fails. Preserve it
      # and return a truthful fallback status instead of masking the nested API outcome.
      Rails.logger.error("Store agent unknown-outcome persistence failed: #{e.full_message}")
      ErrorNotifier.notify(
        e,
        exclude_request_context: true,
        ai_message_id: message.id,
      )
      ACTION_STATUS_EXECUTING
    end

    # After a successful replay, finalize the already-claimed proposal and attach the resulting
    # object. This preserves the post-success audit record while keeping payload matching and the
    # one-shot decision before the mutation.
    def record_agent_action_applied!(message, result)
      metadata = message.reload.metadata
      raise ActiveRecord::StaleObjectError.new(message, "finalize") unless metadata["action_status"] == ACTION_STATUS_EXECUTING

      metadata["action_status"] = ACTION_STATUS_APPLIED
      # Mirror the live UI: once applied, the created/edited object replaces the turn's lookup
      # objects as the thing worth showing.
      metadata["objects"] = [result[:object]] if result[:object].present?
      finalized = nil
      AiMessage.transaction do
        finalized = AiMessage
          .where(id: message.id)
          .where("JSON_UNQUOTE(JSON_EXTRACT(metadata, '$.action_status')) = ?", ACTION_STATUS_EXECUTING)
          .update_all(metadata:, updated_at: Arel.sql("CURRENT_TIMESTAMP(6)"))
        # The JSON compare-and-set bypasses AiMessage's `touch: true` association callback.
        # Keep the audit row and its conversation activity timestamp atomic so a failed touch
        # leaves the claim executing for the controller's unknown-outcome fallback.
        message.ai_conversation.touch if finalized == 1
      end
      raise ActiveRecord::StaleObjectError.new(message, "finalize") unless finalized == 1
    end

    # A process can die after committing the one-shot claim but before the nested request or its
    # final audit write. Reconcile that stranded state only after the full execution horizon above.
    # Both the claim timestamp and age predicate use the database clock, so app-server clock skew
    # cannot recover another node's live request early. The conditional update repeats the exact
    # status and age checks, so a concurrent applied/unknown transition, safe claim release, or
    # newer write wins and can never be overwritten. Read-side repair does not touch the
    # conversation: observing old bookkeeping is not new seller activity and must not reorder chat.
    def reconcile_stale_agent_action!(message)
      metadata = message.metadata || {}
      status = metadata["action_status"]
      return status unless metadata["proposed_action"].present? && status == ACTION_STATUS_EXECUTING

      stale = AiMessage
        .where(id: message.id)
        .where("JSON_UNQUOTE(JSON_EXTRACT(metadata, '$.action_status')) = ?", ACTION_STATUS_EXECUTING)
        .where(
          "updated_at <= DATE_SUB(CURRENT_TIMESTAMP(6), INTERVAL ? SECOND)",
          ACTION_EXECUTION_ABANDONED_AFTER.to_i,
        )
        .exists?
      unless stale
        message.reload
        return message.metadata["action_status"].presence
      end

      status = record_agent_action_outcome_unknown!(
        message,
        stale_after: ACTION_EXECUTION_ABANDONED_AFTER,
        touch_conversation: false,
      )
      message.reload if status != ACTION_STATUS_EXECUTING
      status
    end

    # The shape the chat clients (AgentChat.tsx on web, the Agent tab on mobile) hydrate a resumed
    # conversation from: the plain transcript plus each turn's persisted extras (proposed-action
    # card, object cards, applied/dismissed status) so history re-renders exactly as it did live.
    # Shared here so their base shape stays aligned; `hide_executing_action` is the one deploy-window
    # exception for mobile releases that cannot represent that transient state safely.
    # Hydration is capped at the same window the model replays (HISTORY_MAX_MESSAGES) so a very
    # long conversation doesn't produce a multi-megabyte resume payload — and so what the seller
    # sees matches what the model will be shown on the next turn.
    def agent_conversation_props(conversation, hide_executing_action: false)
      {
        id: conversation.external_id,
        title: conversation.title,
        messages: conversation.ai_messages.last(HISTORY_MAX_MESSAGES).map do |message|
          agent_message_props(message, hide_executing_action:)
        end,
      }
    end

    # One message in the shape the chat clients hydrate from — shared by the conversation resume
    # payload above and the turn-status endpoint (which returns a single recovered turn), so the
    # two can't drift on how persisted extras come back to life.
    def agent_message_props(message, hide_executing_action: false)
      # Hydration is the only reconciliation read installed mobile clients perform, so it also
      # repairs an abandoned execution before deciding whether the proposal card is safe to show.
      reconcile_stale_agent_action!(message)
      metadata = message.metadata || {}
      props = {
        role: message.role,
        content: message.content,
        proposed_action: metadata["proposed_action"],
        objects: metadata["objects"],
        action_status: metadata["action_status"],
      }.compact
      props[:proposal_message_id] = message.external_id if metadata["proposed_action"].present?
      # Current mobile releases only understand "applied" and "dismissed"; passing a claimed state
      # makes them render an enabled Confirm button. Until the native client can represent these
      # states safely, hide the card and replace its now-misleading confirmation text.
      if hide_executing_action && [ACTION_STATUS_EXECUTING, ACTION_STATUS_UNKNOWN].include?(metadata["action_status"])
        props.except!(:proposed_action, :proposal_message_id, :action_status)
        props[:content] = UNRESOLVED_MOBILE_ACTION_REPLY
      end
      props
    end

    def stored_action_payload(message)
      proposal = message.metadata&.dig("proposed_action")
      return if proposal.blank?

      { "type" => proposal["type"], "params" => proposal["params"] }
    end

    def log_missing_proposal_message_id
      Rails.logger.warn(MISSING_PROPOSAL_MESSAGE_ID_NOTICE)
      ErrorNotifier.notify(MISSING_PROPOSAL_MESSAGE_ID_NOTICE, exclude_request_context: true)
    end

    # Match according to the persisted proposal's types. Browsers can serialize a stored numeric
    # 20.0 as 20, and form encoding can send it as "20", so numeric leaves compare by value.
    # Persisted strings remain exact: treating a string such as an offer-code name as a number would
    # let a tampered "1000" confirmation match a seller-approved "1e3".
    def action_payload_matches?(message, executed)
      stored = stored_action_payload(message)
      stored.present? && action_payload_values_match?(stored, executed)
    end

    def action_payload_values_match?(stored, executed)
      case stored
      when Hash
        return false unless executed.is_a?(Hash)

        stored_by_key = action_hash_with_string_keys(stored)
        executed_by_key = action_hash_with_string_keys(executed)
        return false if stored_by_key.nil? || executed_by_key.nil?
        return false unless stored_by_key.keys.sort == executed_by_key.keys.sort

        stored_by_key.all? { |key, value| action_payload_values_match?(value, executed_by_key[key]) }
      when Array
        executed.is_a?(Array) &&
          stored.length == executed.length &&
          stored.zip(executed).all? { |stored_item, executed_item| action_payload_values_match?(stored_item, executed_item) }
      when Numeric
        action_numbers_match?(stored, executed)
      when String
        executed.is_a?(String) && stored == executed
      when true, false
        executed == stored || executed == stored.to_s
      when nil
        executed.nil?
      else
        executed.class == stored.class && executed == stored
      end
    end

    def action_hash_with_string_keys(value)
      value.each_with_object({}) do |(key, child), normalized|
        key = key.to_s
        return if normalized.key?(key)

        normalized[key] = child
      end
    end

    def action_numbers_match?(stored, executed)
      return false unless executed.is_a?(Numeric) ||
        (executed.is_a?(String) && executed.match?(FORM_DECIMAL_NUMBER_PATTERN))

      stored_decimal = bounded_action_decimal(stored)
      executed_decimal = bounded_action_decimal(executed)
      stored_decimal.present? && executed_decimal.present? && stored_decimal == executed_decimal
    end

    def bounded_action_decimal(value)
      source = value.is_a?(BigDecimal) ? value.to_s("E") : value.to_s
      return if source.bytesize > ACTION_NUMBER_INPUT_MAX_BYTES

      decimal = value.is_a?(BigDecimal) ? value : BigDecimal(source, exception: false)
      return unless decimal&.finite?
      return if decimal.zero? && source.split(/[eE]/, 2).first.match?(/[1-9]/)
      return if decimal.exponent.abs > ACTION_NUMBER_MAX_EXPONENT

      decimal
    end
end
