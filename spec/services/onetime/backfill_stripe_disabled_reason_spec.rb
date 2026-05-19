# frozen_string_literal: true

require "spec_helper"

describe Onetime::BackfillStripeDisabledReason do
  describe ".process" do
    def stub_stripe_account(account_id, disabled_reason:)
      allow(Stripe::Account).to receive(:retrieve).with(account_id).and_return(
        Stripe::Account.construct_from(
          id: account_id,
          object: "account",
          requirements: { "disabled_reason" => disabled_reason }
        )
      )
    end

    it "writes the disabled_reason returned by Stripe onto the merchant account" do
      merchant_account = create(:merchant_account, charge_processor_merchant_id: "acct_one")
      stub_stripe_account("acct_one", disabled_reason: "rejected.listed")

      described_class.process

      expect(merchant_account.reload.stripe_disabled_reason).to eq("rejected.listed")
    end

    it "clears the disabled_reason when Stripe no longer reports one" do
      merchant_account = create(:merchant_account, charge_processor_merchant_id: "acct_two", stripe_disabled_reason: "rejected.other")
      stub_stripe_account("acct_two", disabled_reason: nil)

      described_class.process

      expect(merchant_account.reload.stripe_disabled_reason).to be_nil
    end

    it "skips Stripe Connect accounts" do
      merchant_account = create(:merchant_account, charge_processor_merchant_id: "acct_three")
      merchant_account.update!(json_data: merchant_account.json_data.deep_merge("meta" => { "stripe_connect" => "true" }))
      expect(Stripe::Account).not_to receive(:retrieve)

      described_class.process

      expect(merchant_account.reload.stripe_disabled_reason).to be_nil
    end

    it "leaves the value untouched when it already matches what Stripe reports" do
      merchant_account = create(:merchant_account, charge_processor_merchant_id: "acct_four", stripe_disabled_reason: "rejected.listed")
      stub_stripe_account("acct_four", disabled_reason: "rejected.listed")
      expect_any_instance_of(MerchantAccount).not_to receive(:update!)

      described_class.process

      expect(merchant_account.reload.stripe_disabled_reason).to eq("rejected.listed")
    end

    it "skips merchant accounts whose Stripe::Account.retrieve raises and continues with the rest" do
      bad = create(:merchant_account, charge_processor_merchant_id: "acct_bad")
      good = create(:merchant_account, charge_processor_merchant_id: "acct_good")
      allow(Stripe::Account).to receive(:retrieve).with("acct_bad").and_raise(Stripe::APIConnectionError.new("nope"))
      stub_stripe_account("acct_good", disabled_reason: "rejected.fraud")

      expect { described_class.process }.not_to raise_error

      expect(bad.reload.stripe_disabled_reason).to be_nil
      expect(good.reload.stripe_disabled_reason).to eq("rejected.fraud")
    end
  end
end
