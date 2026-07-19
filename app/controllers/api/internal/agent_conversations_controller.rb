# frozen_string_literal: true

# Read side of the persisted store Agent chat (see AgentConversationPersistence for the write
# side). The Agent tab calls `latest` on mount to hydrate the most recently active conversation, so
# a page refresh resumes the chat instead of starting blank — the same resume behavior hosted chat
# products (OpenAI, Claude) have.
#
# Shares the authentication + UserPolicy#use_store_agent? guards with the other agent endpoints,
# but not the LLM throttle: this is a cheap seller-scoped read that must work even when the seller
# has used up their agent-turn quota.
class Api::Internal::AgentConversationsController < Api::Internal::BaseController
  include AgentConversationPersistence

  before_action :authenticate_user!
  before_action :authorize_store_agent
  after_action :verify_authorized

  # GET /internal/agent/conversations/latest
  # Returns { success: true, conversation: null } when the seller has no stored conversations —
  # the client treats that as a fresh chat.
  def latest
    conversation = current_seller.ai_conversations.alive.order(updated_at: :desc, id: :desc).first
    render json: { success: true, conversation: conversation && agent_conversation_props(conversation) }
  end

  # GET /internal/agent/turns/:client_turn_id
  # Recovery read for a streamed turn whose SSE connection broke: the client generated the turn id
  # before sending, so this answers "did MY exact turn persist?" without guessing from the seller's
  # latest conversation (which another tab or device can change at any moment). `status` is:
  #   persisted   -> the turn is stored; `message` is the assistant turn (same shape hydration
  #                  uses) and `conversation_id` is the conversation it landed in
  #   in_progress -> the server is still generating the turn; keep polling
  #   failed      -> the turn errored or couldn't be persisted; it will never appear — stop
  #   unknown     -> no record and no liveness marker (the server died mid-turn, or the marker
  #                  expired); waiting longer won't help
  def turn_status
    turn_id = agent_client_turn_id
    if turn_id.nil?
      render json: { success: false, error: "Invalid turn id." }, status: :bad_request
      return
    end

    message = find_agent_turn_message(turn_id)
    if message
      render json: {
        success: true,
        status: "persisted",
        conversation_id: message.ai_conversation.external_id,
        message: agent_message_props(message),
      }
    else
      marker = agent_turn_marker(turn_id)
      status = %w[in_progress failed].include?(marker) ? marker : "unknown"
      render json: { success: true, status: }
    end
  end

  private
    def authorize_store_agent
      authorize current_seller, :use_store_agent?
    end
end
