# frozen_string_literal: true

require "spec_helper"

describe PurchasePaymentFlow do
  describe "validations" do
    it "rejects an unknown payment details source" do
      flow = build(:purchase_payment_flow, payment_details_source: "venmo")
      expect(flow).not_to be_valid
      expect(flow.errors[:payment_details_source]).to be_present
    end

    it "rejects an unknown payment details transport" do
      flow = build(:purchase_payment_flow, payment_details_transport: "telepathy")
      expect(flow).not_to be_valid
      expect(flow.errors[:payment_details_transport]).to be_present
    end

    it "requires a stripe payment method type" do
      flow = build(:purchase_payment_flow, stripe_payment_method_type: nil)
      expect(flow).not_to be_valid
      expect(flow.errors[:stripe_payment_method_type]).to be_present
    end
  end

  describe ".attributes_for_checkout_params" do
    it "records a Payment Element card from the client surface hint" do
      attributes = described_class.attributes_for_checkout_params(payment_details_source: "payment_element")

      expect(attributes).to eq(
        payment_details_source: "payment_element",
        payment_details_transport: "payment_method",
        stripe_payment_method_type: "card"
      )
    end

    it "records a CardElement card from the client surface hint" do
      attributes = described_class.attributes_for_checkout_params(payment_details_source: "card_element")

      expect(attributes[:payment_details_source]).to eq("card_element")
    end

    it "records a saved card from the client surface hint" do
      attributes = described_class.attributes_for_checkout_params(payment_details_source: "saved_payment_method")

      expect(attributes[:payment_details_source]).to eq("saved_payment_method")
    end

    it "treats a wallet payment as a payment request regardless of the client hint" do
      attributes = described_class.attributes_for_checkout_params(
        wallet_type: "apple_pay",
        payment_details_source: "card_element"
      )

      expect(attributes[:payment_details_source]).to eq("payment_request")
    end

    it "returns nil when no Stripe payment surface is present" do
      expect(described_class.attributes_for_checkout_params({})).to be_nil
    end

    it "returns nil for a non-Stripe surface such as PayPal" do
      expect(described_class.attributes_for_checkout_params(paypal_order_id: "PAY-123")).to be_nil
    end

    it "ignores an unrecognized client surface hint" do
      expect(described_class.attributes_for_checkout_params(payment_details_source: "venmo")).to be_nil
    end
  end
end
