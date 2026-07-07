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
  before_action :authenticate_user!
  before_action :authorize_store_agent
  after_action :verify_authorized

  # GET /internal/agent/conversations/latest
  # Returns { success: true, conversation: null } when the seller has no stored conversations —
  # the client treats that as a fresh chat.
  def latest
    conversation = current_seller.ai_conversations.alive.order(updated_at: :desc, id: :desc).first
    render json: { success: true, conversation: conversation && conversation_props(conversation) }
  end

  private
    def authorize_store_agent
      authorize current_seller, :use_store_agent?
    end

    # The shape AgentChat.tsx hydrates from: the plain transcript plus each turn's persisted
    # extras (proposed-action card, object cards, applied/dismissed status) so history re-renders
    # exactly as it did live.
    def conversation_props(conversation)
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
end
