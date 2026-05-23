# frozen_string_literal: true

require_relative "stripe_charges_helper"
require_relative "stripe_payment_method_helper"

# Ensures that the Stripe test account has a sufficient balance to run the
# suite (e.g. instant payout E2E tests).
class StripeBalanceEnforcer
  include StripeChargesHelper

  # As of July 2025, running the suite requires a balance of ~$70. 100x that as
  # a buffer should be sufficient for the foreseeable future.
  DEFAULT_MINIMUM_BALANCE_CENTS = 70_00 * 100

  def self.ensure_sufficient_balance(minimum_balance_cents = DEFAULT_MINIMUM_BALANCE_CENTS)
    new(minimum_balance_cents).ensure_sufficient_balance
  end

  def initialize(minimum_balance_cents)
    @minimum_balance_cents = minimum_balance_cents
  end

  private_class_method :new

  def ensure_sufficient_balance
    top_up! if insufficient_balance?
  end

  private
    attr_reader :minimum_balance_cents

    def insufficient_balance?
      current_balance_cents < minimum_balance_cents
    end

    def current_balance_cents
      balance = Stripe::Balance.retrieve
      usd_balance = balance.available.find { |b| b["currency"] == "usd" }
      usd_balance ? usd_balance["amount"] : 0
    end

    def top_up!
      available_balance_card = StripePaymentMethodHelper.success_available_balance
      payment_method_id = available_balance_card.to_stripejs_payment_method_id

      create_stripe_charge(
        payment_method_id,
        # This is the maximum amount that can be charged per transaction. Use
        # the largest possible value to reduce top up frequency.
        amount: 999_999_99,
        currency: "usd",
        confirm: true
      )
    end
end
