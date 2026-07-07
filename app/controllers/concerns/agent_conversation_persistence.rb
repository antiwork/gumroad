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

    # The plain role/content transcript to send to the model — rebuilt from the stored rows so a
    # tampered or stale client-side history can't rewrite what the agent believes was said.
    def agent_conversation_history(conversation)
      conversation.ai_messages.map { |message| { role: message.role, content: message.content } }
    end

    def record_agent_user_message!(conversation, content)
      conversation.ai_messages.create!(role: "user", content:)
    end

    # Persists the assistant's turn. The proposed action and looked-up objects ride along in
    # `metadata` so a reloaded conversation re-renders its confirmation card / object cards.
    def record_agent_assistant_message!(conversation, result)
      metadata = {
        proposed_action: result[:proposed_action],
        objects: result[:objects].presence,
      }.compact
      conversation.ai_messages.create!(role: "assistant", content: result[:reply].to_s, metadata: metadata.presence)
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
      message.update_column(:metadata, metadata)
    end

    # The shape the chat clients (AgentChat.tsx on web, the Agent tab on mobile) hydrate a resumed
    # conversation from: the plain transcript plus each turn's persisted extras (proposed-action
    # card, object cards, applied/dismissed status) so history re-renders exactly as it did live.
    # Shared here so web and mobile can never drift apart on the resume payload.
    def agent_conversation_props(conversation)
      {
        id: conversation.external_id,
        title: conversation.title,
        messages: conversation.ai_messages.map do |message|
          metadata = message.metadata || {}
          {
            role: message.role,
            content: message.content,
            proposed_action: metadata["proposed_action"],
            objects: metadata["objects"],
            action_status: metadata["action_status"],
          }.compact
        end,
      }
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
