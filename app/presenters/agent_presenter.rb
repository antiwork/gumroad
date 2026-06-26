# frozen_string_literal: true

# Builds the props for the Agent dashboard tab (the conversational store assistant).
class AgentPresenter
  def initialize(pundit_user:)
    @pundit_user = pundit_user
    @seller = pundit_user.seller
  end

  def index_props
    {
      # A short, friendly first message so the empty chat isn't a blank box.
      greeting: "Hi! I'm your Gumroad store assistant. Ask me about your products, sales, or payouts, " \
                "or tell me a change to make and I'll prepare it for your confirmation.",
      # Surfaced so the UI can suggest concrete starting prompts.
      suggestions: [
        "How are my sales doing?",
        "List my products",
        "Create a 20% off code called LAUNCH",
      ],
    }
  end

  private
    attr_reader :pundit_user, :seller
end
