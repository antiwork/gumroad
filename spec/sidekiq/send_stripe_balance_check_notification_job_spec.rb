# frozen_string_literal: true

require "spec_helper"

describe SendStripeBalanceCheckNotificationJob do
  describe "#perform" do
    before do
      allow(Rails.env).to receive(:production?).and_return(true)
      allow(PayoutEstimates).to receive(:estimate_gumroad_held_stripe_cents).and_return(300_000_00)
    end

    context "when the balance is insufficient" do
      before do
        allow(StripeTransferExternallyToGumroad).to receive(:available_balances).and_return({ "usd" => 200_000_00 })
      end

      it "sends a notification with the required top-up and sets the redis key to true" do
        notification_msg = "Stripe balance needs to be $300,000 to cover upcoming payouts.\n"\
                           "Current Stripe balance is $200,000.\n"\
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

    context "when the disable_stripe_balance_check_notification flag is active" do
      before do
        allow(StripeTransferExternallyToGumroad).to receive(:available_balances).and_return({ "usd" => 200_000_00 })
        Feature.activate(:disable_stripe_balance_check_notification)
      end

      it "does not check the balance, notify, or set the redis key" do
        expect(StripeBalanceCheckService).not_to receive(:new)

        described_class.new.perform

        expect(InternalNotificationWorker.jobs.size).to eq(0)
        expect($redis.get(RedisKey.stripe_balance_topup_needed)).to be_nil
      end
    end
  end
end
