# frozen_string_literal: true

require "spec_helper"

describe SendStripeBalanceCheckNotificationJob do
  describe "#perform" do
    before do
      allow(Rails.env).to receive(:production?).and_return(true)
      allow(PayoutEstimates).to receive(:estimate_gumroad_held_stripe_cents).and_return(300_000_00)
      $redis.set(RedisKey.stripe_minimum_balance_cents, 100_000_00)
    end

    context "when the balance is insufficient" do
      before do
        allow(StripeTransferExternallyToGumroad).to receive(:available_balances).and_return({ "usd" => 300_000_00 })
      end

      it "sends a notification with the required top-up and sets the redis key to true" do
        notification_msg = "Stripe balance needs to be $400,000 ($300,000 for upcoming payouts + $100,000 Stripe minimum balance) to pay out all creators.\n"\
                           "Current Stripe balance is $300,000.\n"\
                           "A top-up of $100,000 is needed."

        described_class.new.perform

        expect(InternalNotificationWorker).to have_enqueued_sidekiq_job("payments", "Stripe Balance Check", notification_msg, "red")
        expect($redis.get(RedisKey.stripe_balance_topup_needed)).to eq("true")
      end
    end

    context "when the balance is sufficient" do
      before do
        allow(StripeTransferExternallyToGumroad).to receive(:available_balances).and_return({ "usd" => 1_000_000_00 })
      end

      it "does not notify and sets the redis key to false" do
        described_class.new.perform

        expect(InternalNotificationWorker.jobs.size).to eq(0)
        expect($redis.get(RedisKey.stripe_balance_topup_needed)).to eq("false")
      end
    end

    it "does nothing outside production" do
      allow(Rails.env).to receive(:production?).and_return(false)

      described_class.new.perform

      expect(InternalNotificationWorker.jobs.size).to eq(0)
    end
  end
end
