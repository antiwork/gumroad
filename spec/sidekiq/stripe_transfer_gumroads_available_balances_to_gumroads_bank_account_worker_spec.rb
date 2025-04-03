# frozen_string_literal: true

require "spec_helper"

describe StripeTransferGumroadsAvailableBalancesToGumroadsBankAccountWorker, :vcr do
  include StripeChargesHelper

  describe "#perform" do
    let(:estimate_held_amount_cents) { { HolderOfFunds::GUMROAD => 30_000_00, HolderOfFunds::STRIPE => 20_000_00 } }

    before do
      create_stripe_charge(StripePaymentMethodHelper.success_available_balance.to_stripejs_payment_method_id,
                           amount: 520_000_00,
                           currency: "usd"
      )
      create_stripe_charge(StripePaymentMethodHelper.success_available_balance.to_stripejs_payment_method_id,
                           amount: 500_000_00,
                           currency: "usd"
      )
      allow(Rails.env).to receive(:staging?).and_return(true)
      allow(PayoutEstimates).to receive(:estimate_held_amount_cents).and_return(estimate_held_amount_cents)
    end

    it "aborts the process if a particular feature flag is set" do
      Feature.activate(:skip_transfer_from_stripe_to_bank)
      expect(StripeTransferExternallyToGumroad).to_not receive(:transfer_all_available_balances)

      described_class.new.perform
    ensure
      Feature.deactivate(:skip_transfer_from_stripe_to_bank)
    end

    it "transfers all available balances with a buffer of 500k+ the expected Stripe connect payouts Gumroad is holding" do
      expect(StripeTransferExternallyToGumroad).to receive(:transfer_all_available_balances).with(buffer_cents: 1_030_000_00).and_call_original

      described_class.new.perform
    end

    it "leaves 530k in the Stripe balance" do
      described_class.new.perform

      balance = Stripe::Balance.retrieve
      usd_available_balance = balance.available.find { |available_balance| available_balance["currency"] == "usd" }
      expect(usd_available_balance["amount"]).to eq(1_030_000_00)
    end
  end
end
