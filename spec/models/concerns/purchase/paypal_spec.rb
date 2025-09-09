# frozen_string_literal: true

require "spec_helper"

describe Purchase::Paypal do
  let(:charge_processor_id) { nil }
  let(:card_visual) { "user@example.com" }
  let(:purchase) { build(:purchase, charge_processor_id:, card_visual:) }

  describe "#paypal_email" do
    context "when charge_processor_id is PayPal" do
      let(:charge_processor_id) { PaypalChargeProcessor.charge_processor_id }

      it "returns card_visual when purchase is PayPal" do
        expect(purchase.paypal_email).to eq(card_visual)
      end
    end

    context "when charge_processor_id is not PayPal" do
      let(:charge_processor_id) { StripeChargeProcessor.charge_processor_id }

      it "returns nil" do
        expect(purchase.paypal_email).to be_nil
      end
    end

    context "when card_visual is blank" do
      let(:charge_processor_id) { PaypalChargeProcessor.charge_processor_id }
      let(:card_visual) { nil }

      it "returns nil" do
        expect(purchase.paypal_email).to be_nil
      end
    end
  end
end
