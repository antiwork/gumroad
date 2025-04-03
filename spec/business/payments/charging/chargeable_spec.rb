# frozen_string_literal: true

require "spec_helper"

describe Chargeable do
  let(:internal_chargeable_1) { double(charge_processor_id: "stripe") }
  let(:internal_chargeable_2) { double(charge_processor_id: "braintree") }
  let(:chargeable) { Chargeable.new([internal_chargeable_1, internal_chargeable_2]) }

  describe "#charge_processor_ids" do
    it "returns all internal chargeables processor ids" do
      expect(chargeable.charge_processor_ids).to eq(%w[stripe braintree])
    end
  end

  describe "#charge_processor_id" do
    it "returns combination of all internal chargeables" do
      expect(chargeable.charge_processor_id).to eq("stripe,braintree")
    end
  end

  describe "#prepare!" do
    it "passes through to first chargeable" do
      expect(internal_chargeable_1).to receive(:prepare!).once.and_return(true)
      expect(internal_chargeable_2).not_to receive(:prepare!)
      expect(chargeable.prepare!).to eq(true)
    end
  end

  describe "#fingerprint" do
    it "passes through to first chargeable" do
      expect(internal_chargeable_1).to receive(:fingerprint).once.and_return("a-fingerprint")
      expect(internal_chargeable_2).not_to receive(:fingerprint)
      expect(chargeable.fingerprint).to eq("a-fingerprint")
    end
  end

  describe "#last4" do
    it "passes through to first chargeable" do
      expect(internal_chargeable_1).to receive(:last4).once.and_return("4242")
      expect(internal_chargeable_2).not_to receive(:last4)
      expect(chargeable.last4).to eq("4242")
    end
  end

  describe "#number_length" do
    it "passes through to first chargeable" do
      expect(internal_chargeable_1).to receive(:number_length).once.and_return(16)
      expect(internal_chargeable_2).not_to receive(:number_length)
      expect(chargeable.number_length).to eq(16)
    end
  end

  describe "#visual" do
    it "passes through to first chargeable" do
      expect(internal_chargeable_1).to receive(:visual).once.and_return("**** **** **** 4242")
      expect(internal_chargeable_2).not_to receive(:visual)
      expect(chargeable.visual).to eq("**** **** **** 4242")
    end
  end

  describe "#expiry_month" do
    it "calls on first chargeable" do
      expect(internal_chargeable_1).to receive(:expiry_month).once.and_return(12)
      expect(internal_chargeable_2).not_to receive(:expiry_month)
      expect(chargeable.expiry_month).to eq(12)
    end
  end

  describe "#expiry_year" do
    it "calls on first chargeable" do
      expect(internal_chargeable_1).to receive(:expiry_year).once.and_return(2014)
      expect(internal_chargeable_2).not_to receive(:expiry_year)
      expect(chargeable.expiry_year).to eq(2014)
    end
  end

  describe "#zip_code" do
    it "calls on first chargeable" do
      expect(internal_chargeable_1).to receive(:zip_code).once.and_return("12345")
      expect(internal_chargeable_2).not_to receive(:zip_code)
      expect(chargeable.zip_code).to eq("12345")
    end
  end

  describe "#card_type" do
    it "calls on first chargeable" do
      expect(internal_chargeable_1).to receive(:card_type).once.and_return("visa")
      expect(internal_chargeable_2).not_to receive(:card_type)
      expect(chargeable.card_type).to eq("visa")
    end
  end

  describe "#country" do
    it "calls on first chargeable" do
      expect(internal_chargeable_1).to receive(:country).once.and_return("US")
      expect(internal_chargeable_2).not_to receive(:country)
      expect(chargeable.country).to eq("US")
    end
  end

  describe "#payment_method_id" do
    it "delegates to the first chargeable" do
      expect(internal_chargeable_1).to receive(:payment_method_id).once.and_return("pm_123456")
      expect(internal_chargeable_2).not_to receive(:payment_method_id)
      expect(chargeable.payment_method_id).to eq("pm_123456")
    end
  end

  describe "#requires_mandate?", :vcr do
    it "returns false if charge processor is not Stripe" do
      expect(create(:native_paypal_chargeable).requires_mandate?).to be false
      expect(create(:paypal_chargeable).requires_mandate?).to be false
    end

    it "return false if charge processor is Stripe and card country is not India" do
      expect(create(:chargeable, card: StripePaymentMethodHelper.success_with_sca).requires_mandate?).to be false
    end

    it "returns true if charge processor is Stripe and card country is India" do
      expect(create(:chargeable, card: StripePaymentMethodHelper.success_indian_card_mandate).requires_mandate?).to be false
    end
  end

  describe "#stripe_setup_intent_id" do
    it "passes through to first chargeable only if it's a Stripe chargeable", :vcr do
      stripe_chargeable = create(:chargeable)
      expect_any_instance_of(StripeChargeablePaymentMethod).to receive(:stripe_setup_intent_id).and_return("seti_123456")
      expect(stripe_chargeable.stripe_setup_intent_id).to be "seti_123456"
    end

    it "returns nil for non-Stripe chargeable" do
      braintree_chargeable = create(:paypal_chargeable)
      expect(braintree_chargeable.stripe_setup_intent_id).to be nil

      paypal_chargeable = create(:native_paypal_chargeable)
      expect(paypal_chargeable.stripe_setup_intent_id).to be nil
    end
  end

  describe "#stripe_payment_intent_id" do
    it "passes through to first chargeable only if it's a Stripe chargeable", :vcr do
      stripe_chargeable = create(:chargeable)
      expect_any_instance_of(StripeChargeablePaymentMethod).to receive(:stripe_payment_intent_id).and_return("pi_123456")
      expect(stripe_chargeable.stripe_payment_intent_id).to be "pi_123456"
    end

    it "returns nil for non-Stripe chargeable" do
      braintree_chargeable = create(:paypal_chargeable)
      expect(braintree_chargeable.stripe_payment_intent_id).to be nil

      paypal_chargeable = create(:native_paypal_chargeable)
      expect(paypal_chargeable.stripe_payment_intent_id).to be nil
    end
  end

  describe "#reusable_token_for!" do
    let(:user) { create(:user) }

    it "returns the respective chargeable's #reusable_token! #1" do
      expect(internal_chargeable_1).to receive(:reusable_token!).with(user).once.and_return("a-reusable-token-1")
      expect(internal_chargeable_2).not_to receive(:reusable_token!)
      expect(chargeable.reusable_token_for!("stripe", user)).to eq("a-reusable-token-1")
    end

    it "returns the respective chargeable's #reusable_token! #2" do
      expect(internal_chargeable_1).not_to receive(:reusable_token!)
      expect(internal_chargeable_2).to receive(:reusable_token!).with(user).once.and_return("a-reusable-token-2")
      expect(chargeable.reusable_token_for!("braintree", user)).to eq("a-reusable-token-2")
    end

    it "returns nil if chargeable not available" do
      expect(internal_chargeable_1).not_to receive(:reusable_token!)
      expect(internal_chargeable_2).not_to receive(:reusable_token!)
      expect(chargeable.reusable_token_for!("something-else", user)).to be_nil
    end
  end

  describe "#can_be_saved?", :vcr do
    it "returns false if underlying chargeable is PaypalApprovedOrderChargeable" do
      chargeable = create(:paypal_approved_order_chargeable)
      expect(chargeable.charge_processor_id).to eq(PaypalChargeProcessor.charge_processor_id)
      expect(chargeable.get_chargeable_for(chargeable.charge_processor_id)).to be_a(PaypalApprovedOrderChargeable)
      expect(chargeable.can_be_saved?).to be(false)
    end

    it "returns true if underlying chargeable is PaypalChargeable" do
      chargeable = create(:native_paypal_chargeable)
      expect(chargeable.charge_processor_id).to eq(PaypalChargeProcessor.charge_processor_id)
      expect(chargeable.get_chargeable_for(chargeable.charge_processor_id)).to be_a(PaypalChargeable)
      expect(chargeable.can_be_saved?).to be(true)
    end

    it "returns true if underlying chargeable is StripeChargeablePaymentMethod" do
      chargeable = create(:chargeable)
      expect(chargeable.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
      expect(chargeable.get_chargeable_for(chargeable.charge_processor_id)).to be_a(StripeChargeablePaymentMethod)
      expect(chargeable.can_be_saved?).to be(true)
    end

    it "returns true if underlying chargeable is StripeChargeableToken" do
      chargeable = create(:cc_token_chargeable)
      expect(chargeable.charge_processor_id).to eq(StripeChargeProcessor.charge_processor_id)
      expect(chargeable.get_chargeable_for(chargeable.charge_processor_id)).to be_a(StripeChargeableToken)
      expect(chargeable.can_be_saved?).to be(true)
    end

    it "returns true if underlying chargeable is BraintreeChargeableNonce" do
      chargeable = create(:paypal_chargeable)
      expect(chargeable.charge_processor_id).to eq(BraintreeChargeProcessor.charge_processor_id)
      expect(chargeable.get_chargeable_for(chargeable.charge_processor_id)).to be_a(BraintreeChargeableNonce)
      expect(chargeable.can_be_saved?).to be(true)
    end
  end

  describe "#get_chargeable_for" do
    it "returns the respective underlying chargeable" do
      expect(chargeable.get_chargeable_for("stripe")).to eq(internal_chargeable_1)
      expect(chargeable.get_chargeable_for("braintree")).to eq(internal_chargeable_2)
    end
    it "returns nil when not available" do
      expect(chargeable.get_chargeable_for("something-else")).to be_nil
    end
  end
end
