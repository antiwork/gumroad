# frozen_string_literal: true

require "spec_helper"

describe SendStripeBalanceCheckNotificationJob do
  describe "#perform" do
    let(:balance_check) do
      instance_double(
        StripeBalanceCheckService,
        upcoming_payouts_cents: 300_000_00,
        available_cents: 150_000_00,
        pending_cents: 50_000_00,
        current_balance_cents: 200_000_00,
        topup_amount_cents: 100_000_00,
        topup_needed?: true,
        payout_end_date: Date.new(2026, 9, 11),
        next_payout_run_at: Time.utc(2026, 9, 16, 10, 0),
        cycle_last_run_at: Time.utc(2026, 9, 18, 10, 0),
        swept_to_bank_last_day_cents: 301_513_34
      )
    end

    before do
      allow(Rails.env).to receive(:production?).and_return(true)
      allow(StripeBalanceCheckService).to receive(:new).and_return(balance_check)
    end

    context "when the balance is insufficient" do
      it "sends a notification naming the deadline, the breakdown and the action, and sets the redis key to true" do
        described_class.new.perform

        expect(InternalNotificationWorker).to have_enqueued_sidekiq_job("payments", "Stripe Balance Check", kind_of(String), "red")
        message = InternalNotificationWorker.jobs.last["args"][2]
        expect(message).to include("Seller payouts for balances up to September 11 need $300,000")
        expect(message).to include("between the next run (Wednesday, September 16 at 10:00 UTC (6:00 AM ET)) and the last run of the cycle (Friday, September 18 at 10:00 UTC (6:00 AM ET)).")
        expect(message).to include("Stripe balance: $200,000 ($150,000 available + $50,000 pending, which normally settles")
        expect(message).to include("Stripe paid $301,513.34 out to Gumroad's bank in the last 24 hours")
        expect(message).to include("A top-up of $100,000 is needed, ideally before Wednesday, September 16 at 10:00 UTC (6:00 AM ET) and no later than Friday, September 18 at 10:00 UTC (6:00 AM ET). Nothing tops up automatically")
        expect($redis.get(RedisKey.stripe_balance_topup_needed)).to eq("true")
      end
    end

    context "when the balance is sufficient" do
      before do
        allow(balance_check).to receive_messages(topup_needed?: false, topup_amount_cents: -100_000_00, current_balance_cents: 400_000_00)
      end

      it "does not notify and sets the redis key to false" do
        $redis.set(RedisKey.stripe_balance_topup_needed, false)

        described_class.new.perform

        expect(InternalNotificationWorker.jobs.size).to eq(0)
        expect($redis.get(RedisKey.stripe_balance_topup_needed)).to eq("false")
      end

      it "sends a green all-clear when the previous check needed a top-up" do
        $redis.set(RedisKey.stripe_balance_topup_needed, true)

        described_class.new.perform

        expect(InternalNotificationWorker).to have_enqueued_sidekiq_job("payments", "Stripe Balance Check", kind_of(String), "green")
        expect(InternalNotificationWorker.jobs.last["args"][2]).to include("No top-up needed: the balance now covers the cycle. Nothing to do.")
        expect($redis.get(RedisKey.stripe_balance_topup_needed)).to eq("false")
      end
    end

    it "does nothing outside production" do
      allow(Rails.env).to receive(:production?).and_return(false)

      described_class.new.perform

      expect(InternalNotificationWorker.jobs.size).to eq(0)
    end

    context "when the disable_stripe_balance_check_notification flag is active" do
      before { Feature.activate(:disable_stripe_balance_check_notification) }

      it "does not check the balance, notify, or set the redis key" do
        expect(StripeBalanceCheckService).not_to receive(:new)

        described_class.new.perform

        expect(InternalNotificationWorker.jobs.size).to eq(0)
        expect($redis.get(RedisKey.stripe_balance_topup_needed)).to be_nil
      end
    end
  end
end
