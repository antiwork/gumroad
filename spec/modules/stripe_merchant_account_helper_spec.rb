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

      it "backs off exponentially up to the cap instead of sleeping a fixed interval" do
        slept = []
        allow(described_class).to receive(:sleep) { |seconds| slept << seconds }
        stub_retrieve(enabled_on_attempt: 8)

        described_class.ensure_charges_enabled(account_id)

        expect(slept).to eq([1, 2, 4, 8, 16, 32, 32])
      end

      it "makes fewer Stripe requests than the old fixed-interval loop while waiting out a slow account" do
        # The old loop polled 12 times at a fixed 10 seconds. Backoff spends the
        # same budget in fewer requests, which matters because every CI shard
        # shares one Stripe test account.
        elapsed = 0
        allow(described_class).to receive(:sleep) { |seconds| elapsed += seconds }
        now = 1_000.0
        allow(described_class).to receive(:monotonic_now) { now + elapsed }
        count = stub_retrieve(enabled_on_attempt: 999)

        expect { described_class.ensure_charges_enabled(account_id) }
          .to raise_error(/Timed out waiting for charges/)
        expect(count.call).to be < 12
      end

      it "still waits the full two-minute budget before giving up, and no longer" do
        elapsed = 0
        allow(described_class).to receive(:sleep) { |seconds| elapsed += seconds }
        # Freeze the clock so only our stubbed sleeps advance it.
        now = 1_000.0
        allow(described_class).to receive(:monotonic_now) { now + elapsed }
        stub_retrieve(enabled_on_attempt: 999)

        expect { described_class.ensure_charges_enabled(account_id) }
          .to raise_error(/Timed out waiting for charges/)
        expect(elapsed).to eq(described_class::CAPABILITIES_WAIT_BUDGET)
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
