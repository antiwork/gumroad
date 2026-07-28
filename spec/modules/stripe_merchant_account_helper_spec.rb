# frozen_string_literal: true

require "spec_helper"

describe StripeMerchantAccountHelper do
  describe ".ensure_charges_enabled" do
    let(:account_id) { "acct_test_capabilities" }

    # Stripe::Account.retrieve returns a fresh object each call. This builds a
    # sequence of responses so we can say "charges are enabled on the Nth poll".
    def stub_retrieve(enabled_on_attempt:)
      calls = 0
      allow(Stripe::Account).to receive(:retrieve) do
        calls += 1
        double(charges_enabled: calls >= enabled_on_attempt)
      end
      -> { calls }
    end

    # The old loop slept a flat 10 seconds, so this is the request count and
    # total sleep it would have spent on an account that verifies after
    # `verified_after` seconds. Used to assert the new schedule never costs more
    # than one extra request against the shared Stripe test account.
    def old_fixed_interval_cost(verified_after)
      requests = 1
      slept = 0
      while slept < verified_after && slept < described_class::CAPABILITIES_WAIT_BUDGET
        slept += 10
        requests += 1
      end
      [requests, slept]
    end

    # Runs the helper against a simulated account that becomes verified
    # `verified_after` seconds in, with sleeps and the clock stubbed so no real
    # time passes. Returns [request count, total seconds slept].
    def poll_until_verified(verified_after)
      slept = 0.0
      allow(described_class).to receive(:sleep) { |seconds| slept += seconds }
      allow(described_class).to receive(:monotonic_now) { 1_000.0 + slept }

      requests = 0
      allow(Stripe::Account).to receive(:retrieve) do
        requests += 1
        double(charges_enabled: slept >= verified_after)
      end

      begin
        described_class.ensure_charges_enabled(account_id)
      rescue RuntimeError => e
        raise unless e.message.include?("Timed out waiting for charges")
      end

      [requests, slept]
    end

    context "when talking to the live Stripe API" do
      before do
        allow(described_class).to receive(:hitting_stripe_api?).and_return(true)
        allow(described_class).to receive(:log_capabilities_wait)
      end

      it "returns after about a second when the account verifies immediately after creation" do
        slept = []
        allow(described_class).to receive(:sleep) { |seconds| slept << seconds }
        stub_retrieve(enabled_on_attempt: 2)

        described_class.ensure_charges_enabled(account_id)

        expect(slept).to eq([1])
      end

      it "probes once after a second and then polls on the same ten-second grid as before" do
        slept = []
        allow(described_class).to receive(:sleep) { |seconds| slept << seconds }
        stub_retrieve(enabled_on_attempt: 9)

        described_class.ensure_charges_enabled(account_id)

        expect(slept).to eq([1, 9, 10, 10, 10, 10, 20, 20])
      end

      # This is the constraint from #6502: all CI shards share one Stripe test
      # account, so a schedule that verifies faster but polls harder would just
      # trade wall clock for the rate-limit errors #6489 had to absorb.
      it "never costs more than one extra Stripe request than the old fixed interval, at any verification time" do
        [0.5, 3, 10, 15, 20, 30, 45, 60, 90, 119].each do |verified_after|
          requests, = poll_until_verified(verified_after)
          old_requests, = old_fixed_interval_cost(verified_after)

          expect(requests - old_requests).to be <= 1,
                                             "account verifying after #{verified_after}s: #{requests} requests vs #{old_requests} on the old fixed interval"
        end
      end

      it "makes fewer Stripe requests than the old fixed interval when the account never verifies" do
        requests, = poll_until_verified(Float::INFINITY)
        old_requests, = old_fixed_interval_cost(described_class::CAPABILITIES_WAIT_BUDGET + 1)

        expect(requests).to be < old_requests
      end

      it "notices a verification no later than the old fixed interval would within the first fifty seconds" do
        [0.5, 3, 10, 15, 20, 30, 45, 50].each do |verified_after|
          _, slept = poll_until_verified(verified_after)
          _, old_slept = old_fixed_interval_cost(verified_after)

          expect(slept).to be <= old_slept,
                           "account verifying after #{verified_after}s: waited #{slept}s vs #{old_slept}s on the old fixed interval"
        end
      end

      it "still waits the full two-minute budget before giving up, and no longer" do
        _, slept = poll_until_verified(Float::INFINITY)

        expect(slept).to eq(described_class::CAPABILITIES_WAIT_BUDGET)
        # The loop also trims its last sleep against the deadline, but only ever
        # needs to because a future schedule edit might overshoot; pin the
        # invariant that keeps the ceiling honest either way.
        expect(described_class::CAPABILITIES_POLL_SCHEDULE.sum).to eq(described_class::CAPABILITIES_WAIT_BUDGET)
      end

      it "raises once the budget is exhausted without the account verifying" do
        allow(described_class).to receive(:sleep)
        allow(described_class).to receive(:monotonic_now).and_return(1_000.0, 2_000.0)
        stub_retrieve(enabled_on_attempt: 999)

        expect { described_class.ensure_charges_enabled(account_id) }
          .to raise_error(/Timed out waiting for charges/)
      end

      it "does not poll at all when the account is already verified" do
        allow(described_class).to receive(:sleep) { raise "should not sleep" }
        count = stub_retrieve(enabled_on_attempt: 1)

        described_class.ensure_charges_enabled(account_id)

        expect(count.call).to eq(1)
      end
    end

    context "when replaying a recorded cassette" do
      before do
        allow(described_class).to receive(:hitting_stripe_api?).and_return(false)
        allow(described_class).to receive(:log_capabilities_wait)
      end

      it "never sleeps" do
        allow(described_class).to receive(:sleep) { raise "should not sleep on the cassette path" }
        stub_retrieve(enabled_on_attempt: 4)

        expect { described_class.ensure_charges_enabled(account_id) }.not_to raise_error
      end

      it "gives up after the attempt ceiling rather than looping forever" do
        count = stub_retrieve(enabled_on_attempt: 999)

        expect { described_class.ensure_charges_enabled(account_id) }
          .to raise_error(/Timed out waiting for charges/)
        expect(count.call).to eq(described_class::MAX_ATTEMPTS_TO_WAIT_FOR_CAPABILITIES + 1)
      end
    end
  end
end
