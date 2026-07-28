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

  # Whether this run needs a live balance top-up.
  #
  # `ensure_sufficient_balance` is not a passive check: it reads the balance live
  # and, when the account is short, creates a payment method and charges
  # $999,999.99 to refill it — against the single Stripe test account every CI
  # shard shares. This used to be gated on `type: :system`, so that request was
  # spent on every browser-spec run before a single example executed.
  #
  # Nothing in the suite needs it today. Every spec that moves a Stripe balance
  # (`InstantPayoutsService`, `StripeTransferInternallyToCreator`,
  # `StripeTransferExternallyToGumroad`) runs under `:vcr` or stubs the service,
  # and none is a `:system` spec. The browser spec that looks like it spends funds
  # — `balance_pages_spec.rb` — stubs `InstantPayoutsService#perform` and builds
  # payout rows as factories.
  #
  # Kept as an opt-in rather than deleted: a spec that genuinely needs live funds
  # can tag itself `spend_stripe_balance: true` and get the old behaviour for that
  # run alone, instead of for the whole fleet.
  def self.needed_for?(examples)
    examples.any? { |example| example.metadata[:spend_stripe_balance] }
  end

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
