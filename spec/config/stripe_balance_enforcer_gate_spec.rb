# frozen_string_literal: true

require "spec_helper"

# Guards the gate added for gumroad#6489: the Stripe balance top-up must not run
# just because a suite contains browser specs.
#
# `StripeBalanceEnforcer.ensure_sufficient_balance` is not a passive check. It
# reads the balance live and, when the account is short, creates a payment method
# and charges $999,999.99 to refill it — against the single Stripe test account
# every CI shard shares. Triggering it for `type: :system` meant that request was
# spent on every browser-spec run before a single example executed.
#
# These examples assert on the enforcer's own decision rather than on some other
# spec passing: a green suite is exactly what we had while the enforcer was
# firing, so green was never evidence the request had stopped.
describe StripeBalanceEnforcer do
  describe ".ensure_sufficient_balance_once" do
    # The memo is process-global on purpose (one live top-up per RSpec process),
    # so each example has to put it back the way it found it.
    around do |example|
      previous = described_class.instance_variable_get(:@balance_ensured)
      example.run
      described_class.instance_variable_set(:@balance_ensured, previous)
    end

    before { described_class.instance_variable_set(:@balance_ensured, nil) }

    it "tops the account up the first time an example needs it" do
      expect(described_class).to receive(:ensure_sufficient_balance).once

      described_class.ensure_sufficient_balance_once
    end

    it "does not charge the account again for later examples in the same process" do
      expect(described_class).to receive(:ensure_sufficient_balance).once

      3.times { described_class.ensure_sufficient_balance_once }
    end

    it "does not retry after a failed attempt, so one bad response cannot become many charges" do
      expect(described_class).to receive(:ensure_sufficient_balance).once
        .and_raise(Stripe::APIError.new("boom"))

      expect { described_class.ensure_sufficient_balance_once }.to output(/Stripe balance check failed/).to_stderr

      described_class.ensure_sufficient_balance_once
    end

    it "reports whether this process has already attempted its top-up" do
      allow(described_class).to receive(:ensure_sufficient_balance)

      expect(described_class.balance_ensured?).to be false
      described_class.ensure_sufficient_balance_once
      expect(described_class.balance_ensured?).to be true
    end

    # Running per example rather than at suite start means the top-up now arrives
    # while VCR and WebMock are configured for the current example. A non-`:js`
    # example blocks outbound HTTP, which would make the live balance read fail
    # and get swallowed by the warn above — the top-up would silently never
    # happen. The enforcer opens the connection for the duration of the call.
    it "reaches Stripe even from an example where outbound HTTP is blocked" do
      expect(WebMock::Config.instance.allow_net_connect).to be_falsey

      allowed_during_call = nil
      vcr_on_during_call = nil
      allow(described_class).to receive(:ensure_sufficient_balance) do
        allowed_during_call = WebMock::Config.instance.allow_net_connect
        vcr_on_during_call = VCR.turned_on?
      end

      described_class.ensure_sufficient_balance_once

      expect(allowed_during_call).to be true
      expect(vcr_on_during_call).to be false
    end

    it "restores the example's HTTP settings afterwards" do
      allow(described_class).to receive(:ensure_sufficient_balance)

      expect { described_class.ensure_sufficient_balance_once }
        .to not_change { WebMock::Config.instance.allow_net_connect }
        .and not_change { VCR.turned_on? }
    end

    it "restores the example's HTTP settings even when the top-up raises" do
      allow(described_class).to receive(:ensure_sufficient_balance)
        .and_raise(Stripe::APIError.new("boom"))

      expect do
        expect { described_class.ensure_sufficient_balance_once }
          .to output(/Stripe balance check failed/).to_stderr
      end.to not_change { WebMock::Config.instance.allow_net_connect }
        .and not_change { VCR.turned_on? }
    end
  end

  describe "the trigger lives on the example, not on the suite" do
    # This is the part queue mode breaks. `rake knapsack_pro:queue:rspec` loads
    # spec files in batches from inside the suite hooks, so
    # `RSpec.world.filtered_examples` is empty while `before(:suite)` runs and a
    # suite-level check would never see a tagged example. Asserting on the hook's
    # shape is the only cheap way to keep someone from moving it back.
    let(:source) { File.read(Rails.root.join("spec/spec_helper.rb")) }

    it "hooks the top-up on the spend_stripe_balance tag per example" do
      expect(source).to include("config.before(:each, :spend_stripe_balance)")
      expect(source).to include("StripeBalanceEnforcer.ensure_sufficient_balance_once")
    end

    it "does not decide from the loaded example list, which is empty in queue mode" do
      suite_hook_bodies = source.scan(/config\.before\(:suite\) do(.*?)\n  end/m).flatten.join("\n")

      expect(suite_hook_bodies).not_to include("StripeBalanceEnforcer")
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
    # The claim the gate rests on. Derived by sweeping the whole spec suite
    # instead of naming files, so a new spec that transfers live funds without
    # opting in fails here rather than surfacing as `balance_insufficient` in CI
    # weeks later.
    #
    # The sweep sees DIRECT textual references only. A spec can still reach a live
    # transfer indirectly — `Purchase#increment_affiliates_balance!` reaches
    # `StripeTransferAffiliateCredits` when an affiliate has their own Stripe
    # merchant account, with no mention of any name below. Nothing does that today
    # (affiliates in specs use Gumroad-held accounts), so this is a tripwire for
    # the common case rather than a proof of absence.
    #
    # The entry points are the ones that end in a live `Stripe::Transfer` or
    # `Stripe::Payout` out of the shared platform balance. `described_class` in a
    # spec whose subject IS the entry point defeats class-name matching, so the
    # bare method names are listed too.
    def balance_moving_entry_points
      [
        "Payouts.create_payment",
        "create_payments_for_balances",
        "StripeTransferInternallyToCreator",
        "StripeTransferExternallyToGumroad",
        "StripeTransferAffiliateCredits",
        "InstantPayoutsService",
        "PayoutUsersService",
        "Stripe::Transfer.create",
        "Stripe::Payout.create",
      ]
    end

    # A spec is safe if the call never reaches Stripe: it replays from a cassette,
    # or the transfer-performing collaborator is doubled or stubbed. A stub only
    # counts when it names one of the entry points — a spec stubbing something
    # unrelated should not buy itself a pass.
    def neutralized?(source)
      return true if source.match?(/:vcr\b|VCR\.use_cassette/)

      stub_forms = /(?:instance_double|class_double|allow_any_instance_of|allow|expect)\(\s*([A-Za-z0-9_:.]+)/
      source.scan(stub_forms).flatten.any? do |stubbed|
        balance_moving_entry_points.any? { |entry_point| stubbed.include?(entry_point.split(".").first) }
      end
    end

    # This gate spec names the entry points in order to grep for them.
    def exempt_from_sweep
      ["spec/config/stripe_balance_enforcer_gate_spec.rb"]
    end

    def suspect_spec_files
      Dir[Rails.root.join("spec/**/*_spec.rb")].sort.reject do |path|
        exempt_from_sweep.any? { |exempt| path.end_with?(exempt) }
      end.select do |path|
        source = File.read(path)
        balance_moving_entry_points.any? { |entry_point| source.include?(entry_point) }
      end
    end

    it "finds the balance-moving specs it is supposed to be checking" do
      # Guards the sweep itself: if a rename empties this list, the assertion
      # below would pass vacuously and prove nothing.
      expect(suspect_spec_files.size).to be >= 10
    end

    it "sweeps the specs whose subject is the entry point itself" do
      # `described_class.create_payments_for_balances_up_to_date` and a direct
      # `Stripe::Transfer.create` are both invisible to a plain class-name grep,
      # and both were missed by the earlier version of this sweep.
      swept = suspect_spec_files.map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }

      expect(swept).to include(
        "spec/business/payments/payouts/payouts_spec.rb",
        "spec/services/payout_users_service_spec.rb"
      )
    end

    it "keeps every balance-moving spec either tagged or neutralized" do
      offenders = suspect_spec_files.reject do |path|
        source = File.read(path)
        source.include?("spend_stripe_balance") || neutralized?(source)
      end.map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }

      expect(offenders).to be_empty, <<~MESSAGE
        These specs reach a live Stripe balance transfer without replaying it from a
        cassette, stubbing the transfer, or tagging `spend_stripe_balance: true`:

        #{offenders.join("\n")}

        Prefer VCR or a stub. Only tag the spec when it genuinely has to transfer —
        the tag charges the shared Stripe test account $999,999.99 when it runs low.
        Note that VCR is turned off for `:js` specs, so a browser spec has to stub or tag.
      MESSAGE
    end

    it "tags the balance-pages past-payouts context, which does a live transfer" do
      # The one spec that genuinely spends the balance. Stated explicitly so that
      # removing its tag fails here instead of draining the account.
      source = File.read(Rails.root.join("spec/requests/balance_pages_spec.rb"))
      expect(source).to include(%(describe "past payouts", spend_stripe_balance: true))
    end

    it "keeps the balance-pages instant-payout context on a stubbed service" do
      # Distinct from the past-payouts context above: this one never transfers,
      # because the service itself is stubbed.
      source = File.read(Rails.root.join("spec/requests/balance_pages_spec.rb"))
      expect(source).to include("allow_any_instance_of(InstantPayoutsService)")
    end
  end
end
