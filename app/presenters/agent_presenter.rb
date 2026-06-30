# frozen_string_literal: true

# Builds the props for the Agent dashboard tab (the conversational store assistant).
#
# The greeting and starter suggestions are defined as constants so the mobile Agent endpoints
# (Api::Mobile::AgentController#meta) can serve the exact same copy without duplicating it.
class AgentPresenter
  # A short, friendly first message so the empty chat isn't a blank box.
  GREETING = "Hi! Ask about your store, or tell me a change to make — I'll always check with you first."

  # Surfaced so the UI can suggest concrete starting prompts.
  SUGGESTIONS = [
    "How are my sales doing?",
    "List my products",
    "Create a 20% off code called LAUNCH",
  ].freeze

  def initialize(pundit_user:)
    @pundit_user = pundit_user
    @seller = pundit_user.seller
  end

  def index_props
    {
      greeting: GREETING,
      suggestions: SUGGESTIONS,
    }
  end

  private
    attr_reader :pundit_user, :seller
end
