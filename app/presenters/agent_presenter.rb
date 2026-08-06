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

  # Copy for a seller who can see the tab but has not earned agent access yet. Sales and payout
  # both land at $100, so it reads as one threshold rather than two hurdles.
  LOCKED_HEADING = "Agent unlocks after your first payout"
  LOCKED_EXPLANATION = "The Agent can read your store and make changes to it, so it opens once you " \
                       "have #{MoneyFormatter.format(User::MIN_SALES_CENTS_VALUE_FOR_STORE_AGENT, :usd, no_cents_if_whole: true, symbol: true)} " \
                       "in sales and your first payout has completed. Nothing to apply for — it appears here on its own."

  # Short form of the same threshold for the nav row badge (gumroad-private#1773), where the full
  # LOCKED_EXPLANATION sentence has no room.
  LOCKED_NAV_BADGE = "#{MoneyFormatter.format(User::MIN_SALES_CENTS_VALUE_FOR_STORE_AGENT, :usd, no_cents_if_whole: true, symbol: true)} to unlock"

  def initialize(pundit_user:)
    @pundit_user = pundit_user
    @seller = pundit_user.seller
  end

  def index_props
    {
      greeting: GREETING,
      suggestions: SUGGESTIONS,
      eligible: seller.eligible_for_store_agent?,
      locked_heading: LOCKED_HEADING,
      locked_explanation: LOCKED_EXPLANATION,
    }
  end

  private
    attr_reader :pundit_user, :seller
end
