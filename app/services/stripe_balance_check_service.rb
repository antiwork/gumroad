# frozen_string_literal: true

# Determines whether Gumroad's Stripe platform balance is large enough to
# fund the upcoming seller payouts. Stripe pays out Gumroad's balance to
# Gumroad's bank automatically, and seller payouts (platform -> connected
# account transfers) draw from the same balance, so the balance can be
# starved before a payout cycle runs. This service powers a proactive alert
# so the balance can be topped up before any seller payout fails.
class StripeBalanceCheckService
  def initialize
    @upcoming_payouts_cents = calculate_upcoming_payouts_cents
    @current_balance_cents = StripeTransferExternallyToGumroad.available_balances["usd"].to_i
  end

  attr_reader :upcoming_payouts_cents, :current_balance_cents

  def topup_amount_cents
    @topup_amount_cents ||= upcoming_payouts_cents - current_balance_cents
  end

  def topup_needed?
    topup_amount_cents > 0
  end

  private
    # Only the funds Gumroad itself holds need to come out of Gumroad's Stripe
    # balance; balances held by Stripe are funded by Stripe directly.
    def calculate_upcoming_payouts_cents
      PayoutEstimates.estimate_gumroad_held_stripe_cents(
        User::PayoutSchedule.next_scheduled_payout_end_date
      )
    end
end
