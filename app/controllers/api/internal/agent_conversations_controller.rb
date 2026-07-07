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

  private
    def authorize_store_agent
      authorize current_seller, :use_store_agent?
    end
end
