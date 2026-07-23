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
      attributes = described_class.attributes_for_checkout_params(payment_details_source: "payment_element", stripe_payment_method_id: "pm_123")

      expect(attributes).to eq(
        payment_details_source: "payment_element",
        payment_details_transport: "payment_method",
        stripe_payment_method_type: "card"
      )
    end

    it "records a CardElement card from the client surface hint" do
      attributes = described_class.attributes_for_checkout_params(payment_details_source: "card_element", stripe_payment_method_id: "pm_123")

      expect(attributes[:payment_details_source]).to eq("card_element")
    end

    it "records a saved card from the client surface hint" do
      attributes = described_class.attributes_for_checkout_params(payment_details_source: "saved_payment_method")

      expect(attributes[:payment_details_source]).to eq("saved_payment_method")
    end

    it "treats a wallet payment as a payment request regardless of the client hint" do
      attributes = described_class.attributes_for_checkout_params(
        wallet_type: "apple_pay",
        payment_details_source: "card_element",
        stripe_payment_method_id: "pm_123"
      )

      expect(attributes[:payment_details_source]).to eq("payment_request")
    end

    it "records a wallet paid through the Payment Element (server-confirm lane) as payment_element" do
      attributes = described_class.attributes_for_checkout_params(
        wallet_type: "apple_pay",
        payment_details_source: "payment_element",
        stripe_payment_method_id: "pm_123"
      )

      expect(attributes).to eq(
        payment_details_source: "payment_element",
        payment_details_transport: "payment_method",
        stripe_payment_method_type: "card"
      )
    end

    it "records a wallet payment without the payment_element hint as a payment request, the PRB shape" do
      attributes = described_class.attributes_for_checkout_params(
        wallet_type: "google_pay",
        stripe_payment_method_id: "pm_123"
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

    it "does not record a Stripe flow for a PayPal submission even with a forged source hint" do
      expect(described_class.attributes_for_checkout_params(payment_details_source: "payment_element", paypal_order_id: "PAY-123")).to be_nil
      expect(described_class.attributes_for_checkout_params(payment_details_source: "card_element", billing_agreement_id: "BA-123")).to be_nil
    end

    it "does not record a Stripe flow for a Braintree submission even with a forged source hint" do
      expect(described_class.attributes_for_checkout_params(payment_details_source: "payment_element", braintree_transient_customer_store_key: "store_key")).to be_nil
      expect(described_class.attributes_for_checkout_params(payment_details_source: "card_element", braintree_device_data: "{}")).to be_nil
    end

    it "does not record when a Stripe source is reported without any Stripe payment input" do
      expect(described_class.attributes_for_checkout_params(payment_details_source: "payment_element")).to be_nil
      expect(described_class.attributes_for_checkout_params(wallet_type: "apple_pay", payment_details_source: "payment_element")).to be_nil
    end

    it "records a saved-card flow without a card param, since Rails charges the stored Stripe card" do
      expect(described_class.attributes_for_checkout_params(payment_details_source: "saved_payment_method")[:payment_details_source]).to eq("saved_payment_method")
    end

    it "does not record a saved-card flow when a new Stripe PaymentMethod is also submitted" do
      expect(described_class.attributes_for_checkout_params(payment_details_source: "saved_payment_method", stripe_payment_method_id: "pm_123")).to be_nil
    end

    it "does not record a saved-card flow when a confirmation_token is also submitted, rather than misclassifying it as client-confirm" do
      expect(described_class.attributes_for_checkout_params(payment_details_source: "saved_payment_method", confirmation_token: "ctoken_123")).to be_nil
    end

    it "records the confirmation_token transport for a client-confirm submission" do
      attributes = described_class.attributes_for_checkout_params(payment_details_source: "payment_element", confirmation_token: "ctoken_123")

      expect(attributes).to eq(
        payment_details_source: "payment_element",
        payment_details_transport: "confirmation_token",
        stripe_payment_method_type: "card"
      )
    end

    it "records a client-confirm wallet payment as payment_element over the confirmation_token transport" do
      attributes = described_class.attributes_for_checkout_params(
        wallet_type: "apple_pay",
        payment_details_source: "payment_element",
        confirmation_token: "ctoken_123"
      )

      expect(attributes[:payment_details_source]).to eq("payment_element")
      expect(attributes[:payment_details_transport]).to eq("confirmation_token")
    end

    it "prefers the confirmation_token transport when a PaymentMethod id is also present" do
      attributes = described_class.attributes_for_checkout_params(
        payment_details_source: "payment_element",
        confirmation_token: "ctoken_123",
        stripe_payment_method_id: "pm_123"
      )

      expect(attributes[:payment_details_transport]).to eq("confirmation_token")
    end

    it "does not record a Stripe flow for a PayPal submission carrying a forged confirmation_token" do
      expect(described_class.attributes_for_checkout_params(payment_details_source: "payment_element", confirmation_token: "ctoken_123", paypal_order_id: "PAY-123")).to be_nil
    end
  end
end
