# frozen_string_literal: true

require "spec_helper"

# Guards the gate added for gumroad#6489: the Stripe balance top-up must not run
# just because a suite contains browser specs.
#
# `StripeBalanceEnforcer.ensure_sufficient_balance` is not a passive check. It
# reads the balance live and, when the account is short, creates a payment method
# and charges $999,999.99 to refill it — against the single Stripe test account
# every CI shard shares. Gating it on `type: :system` meant that request was spent
# on every browser-spec run before a single example executed.
#
# These examples call the real `needed_for?` predicate the suite hook uses, and
# assert on its decision rather than on some other spec passing: a green suite is
# exactly what we had while the enforcer was firing, so green was never evidence
# the request had stopped.
describe StripeBalanceEnforcer do
  # Minimal stand-in for an RSpec example: the predicate only reads `.metadata`.
  def example_with(metadata)
    instance_double(RSpec::Core::Example, metadata:)
  end

  describe ".needed_for?" do
    it "is false for an ordinary browser spec" do
      expect(described_class.needed_for?([example_with(type: :system, js: true)])).to be false
    end

    it "is false for a non-system spec" do
      expect(described_class.needed_for?([example_with({})])).to be false
    end

    it "is false for an empty run" do
      expect(described_class.needed_for?([])).to be false
    end

    it "is true only when a spec opts in with spend_stripe_balance" do
      expect(
        described_class.needed_for?([example_with(type: :system, spend_stripe_balance: true)])
      ).to be true
    end

    it "is true when any one spec in a mixed run opts in" do
      expect(
        described_class.needed_for?(
          [
            example_with(type: :system, js: true),
            example_with({}),
            example_with(spend_stripe_balance: true),
          ]
        )
      ).to be true
    end
  end

  describe "the cost the gate avoids" do
    it "still describes a live, money-moving call" do
      # If the top-up ever stops charging the shared account, the gate can be
      # revisited — so assert on what makes it expensive, not that it exists.
      source = File.read(Rails.root.join("spec/support/stripe_balance_enforcer.rb"))
      expect(source).to include("Stripe::Balance.retrieve")
      expect(source).to include("amount: 999_999_99")
    end
  end

  describe "the premise: only the specs that move real funds opt in" do
    # The claim this gate rests on. Stated as an assertion about the ONE context
    # that genuinely transfers live funds, so that removing its tag fails here
    # rather than surfacing as `balance_insufficient` in CI weeks later.
    it "tags the balance-pages past-payouts context, which does a live transfer" do
      source = File.read(Rails.root.join("spec/requests/balance_pages_spec.rb"))
      expect(source).to include(%(describe "past payouts", spend_stripe_balance: true))
    end

    it "keeps every other balance-moving spec on VCR or a stub" do
      %w[
        spec/services/instant_payouts_service_spec.rb
        spec/business/payments/transfers/stripe/stripe_transfer_internally_to_creator_spec.rb
        spec/business/payments/transfers/stripe/stripe_transfer_externally_to_gumroad_spec.rb
      ].each do |path|
        source = File.read(Rails.root.join(path))
        expect(source).to match(/:vcr|instance_double|allow_any_instance_of/),
                          "#{path} moves a Stripe balance without VCR or a stub"
      end
    end

    it "keeps the balance-pages instant-payout context on a stubbed service" do
      # Distinct from the past-payouts context above: this one never transfers,
      # because the service itself is stubbed.
      source = File.read(Rails.root.join("spec/requests/balance_pages_spec.rb"))
      expect(source).to include("allow_any_instance_of(InstantPayoutsService)")
    end
  end
end
