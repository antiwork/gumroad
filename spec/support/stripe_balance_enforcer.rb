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

  MUTEX = Mutex.new

  # Tops the shared Stripe test account up at most once per RSpec process, and
  # only when an example that actually spends the balance is about to run.
  #
  # `ensure_sufficient_balance` is not a passive check: it reads the balance live
  # and, when the account is short, creates a payment method and charges
  # $999,999.99 to refill it — against the single Stripe test account every CI
  # shard shares. It used to be triggered from a `before(:suite)` hook that
  # looked for `type: :system` examples, so that request was spent on every
  # browser-spec run before a single example executed, including the
  # overwhelming majority that never touch a Stripe balance.
  #
  # The trigger cannot live in `before(:suite)` at all. In CI the suite runs
  # through knapsack_pro's queue mode (`rake knapsack_pro:queue:rspec`), which
  # loads spec files in batches from *inside* the suite hooks, so
  # `RSpec.world.filtered_examples` is still empty when `before(:suite)` fires
  # and no tagged example is visible yet. Anything that decides based on the
  # loaded examples at that point sees nothing and skips the top-up, which would
  # leave the one spec that genuinely transfers funds failing with
  # `balance_insufficient` once the shared account drains.
  #
  # So the decision is made per example instead: `spec_helper.rb` calls this from
  # a `before(:each, :spend_stripe_balance)` hook, which works identically in
  # queue mode and in a plain local `rspec` run. The memo keeps it to one live
  # top-up per process no matter how many tagged examples run.
  #
  # One spec genuinely does spend the balance: the "past payouts" context in
  # `spec/requests/balance_pages_spec.rb`. It is a `:js` spec (so VCR is off) and
  # its setup calls `Payouts.create_payment`, which reaches
  # `StripeTransferInternallyToCreator.transfer_funds_to_account` and performs a
  # live `Stripe::Transfer` out of the shared platform balance. That context
  # carries `spend_stripe_balance: true`.
  #
  # If a new spec starts moving real funds, tag it `spend_stripe_balance: true`.
  # The symptom of forgetting is a loud, attributable `balance_insufficient` from
  # Stripe in that one file — not a silent wrong answer.
  def self.ensure_sufficient_balance_once(minimum_balance_cents = DEFAULT_MINIMUM_BALANCE_CENTS)
    MUTEX.synchronize do
      return if @balance_ensured

      # Set before the attempt: a failure is warned about and not retried, which
      # is how the old suite-level hook behaved. Retrying per example could turn
      # one bad Stripe response into hundreds of live requests.
      @balance_ensured = true

      begin
        ensure_sufficient_balance(minimum_balance_cents)
      rescue StandardError => e
        warn "Stripe balance check failed: #{e.class} #{e.message}"
      end
    end
  end

  # Whether this process has already attempted its one top-up.
  def self.balance_ensured?
    MUTEX.synchronize { !!@balance_ensured }
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
