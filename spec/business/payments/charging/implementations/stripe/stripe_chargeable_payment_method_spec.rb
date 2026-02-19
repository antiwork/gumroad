# frozen_string_literal: true

require "spec_helper"
require "business/payments/charging/chargeable_protocol"
require "business/payments/charging/implementations/stripe/stripe_chargeable_common_shared_examples"

describe StripeChargeablePaymentMethod, :vcr do
  let(:number) { "4242 4242 4242 4242" }
  let(:expiry_month) { 12 }
  let(:expiry_year) { 2050 }
  let(:cvc) { "123" }
  let(:zip_code) { "12345" }
  let(:stripe_payment_method) do
    Stripe::PaymentMethod.create(type: "card",
                                 card: { number:, exp_month: expiry_month, exp_year: expiry_year, cvc: },
                                 billing_details: { address: { postal_code: zip_code } })
  end
  let(:stripe_payment_method_id) { stripe_payment_method.id }
  let(:chargeable) { StripeChargeablePaymentMethod.new(stripe_payment_method_id, zip_code:, product_permalink: "xx") }
  let(:user) { create(:user) }

  it_behaves_like "a chargeable"

  include_examples "stripe chargeable common"

  describe "#prepare!" do
    it "retrieves token details from stripe" do
      expect(Stripe::PaymentMethod).to receive(:retrieve).with(stripe_payment_method_id).and_call_original
      chargeable.prepare!
    end

    it "does not prepare for direct charge if merchant account is not a stripe connect account" do
      allow_any_instance_of(StripeChargeablePaymentMethod).to receive(:get_merchant_account).and_return(create(:merchant_account))
      expect(Stripe::PaymentMethod).to receive(:retrieve).with(stripe_payment_method_id).and_call_original
      expect_any_instance_of(StripeChargeablePaymentMethod).not_to receive(:prepare_for_direct_charge)

      chargeable.prepare!
    end

    it "prepares for direct charge if merchant account is a stripe connect account" do
      allow_any_instance_of(StripeChargeablePaymentMethod).to receive(:get_merchant_account).and_return(create(:merchant_account_stripe_connect))
      expect(Stripe::PaymentMethod).to receive(:retrieve).with(stripe_payment_method_id).and_call_original
      expect_any_instance_of(StripeChargeablePaymentMethod).to receive(:prepare_for_direct_charge)

      chargeable.prepare!
    end
  end

  describe "#reusable_token!" do
    it "uses stripe to get a reusable token" do
      expect(Stripe::Customer)
        .to receive(:create)
        .with(hash_including(payment_method: stripe_payment_method_id,
                             description: user.id.to_s,
                             email: user.email))
        .and_return(OpenStruct.new(id: "cus_testcustomer"))
      expect(chargeable.reusable_token!(user)).to eq "cus_testcustomer"
    end
  end

  describe "#visual" do
    it "calls ChargeableVisual to build a visual" do
      expect(ChargeableVisual).to receive(:build_visual).with("4242", 16).and_call_original
      chargeable.prepare!
      expect(chargeable.visual).to eq("**** **** **** 4242")
    end
  end

  describe "#stripe_charge_params" do
    it "returns the original customer and payment method details if merchant account is not a stripe connect account" do
      allow_any_instance_of(StripeChargeablePaymentMethod).to receive(:get_merchant_account).and_return(create(:merchant_account))
      expect(Stripe::PaymentMethod).to receive(:retrieve).with(stripe_payment_method_id).and_call_original
      expect_any_instance_of(StripeChargeablePaymentMethod).not_to receive(:prepare_for_direct_charge)

      chargeable.prepare!

      expect(chargeable.stripe_charge_params[:payment_method]).to be_present
      expect(chargeable.stripe_charge_params[:payment_method]).to eq(stripe_payment_method_id)
    end

    context "when customer_id is provided from a prior SetupIntent authentication" do
      let(:payment_method_id) { "pm_test_123" }
      let(:stripe_payment_method_object) { OpenStruct.new(id: payment_method_id, customer: "cus_other", card: { last4: "4242", brand: "visa", funding: "credit", fingerprint: "fp_123", exp_month: 12, exp_year: 2050, country: "US" }, billing_details: { address: { postal_code: "12345" } }) }
      let(:chargeable) do
        StripeChargeablePaymentMethod.new(payment_method_id,
                                          customer_id: "cus_authenticated",
                                          stripe_setup_intent_id: "seti_123",
                                          zip_code:, product_permalink: "xx")
      end

      before do
        allow(Stripe::PaymentMethod).to receive(:retrieve).with(payment_method_id).and_return(stripe_payment_method_object)
      end

      it "includes the authenticated customer in charge params so Stripe can skip SCA" do
        allow_any_instance_of(StripeChargeablePaymentMethod).to receive(:get_merchant_account).and_return(create(:merchant_account))

        chargeable.prepare!

        # The explicitly-provided customer_id takes precedence over the payment method's customer
        expect(chargeable.stripe_charge_params).to eq(customer: "cus_authenticated", payment_method: payment_method_id)
      end

      it "uses the authenticated customer when cloning the payment method for Connect direct charges" do
        allow_any_instance_of(StripeChargeablePaymentMethod).to receive(:get_merchant_account).and_return(create(:merchant_account_stripe_connect))

        # prepare_for_direct_charge calls reusable_token!(nil) which should return the
        # existing customer_id instead of creating a new Stripe customer
        expect(Stripe::Customer).not_to receive(:create)
        allow(Stripe::PaymentMethod).to receive(:create).and_return(OpenStruct.new(id: "pm_cloned_456"))

        chargeable.prepare!

        expect(chargeable.reusable_token!(nil)).to eq("cus_authenticated")
      end
    end

    it "returns the cloned payment method details if merchant account is a stripe connect account" do
      allow_any_instance_of(StripeChargeablePaymentMethod).to receive(:get_merchant_account).and_return(create(:merchant_account_stripe_connect))
      expect(Stripe::PaymentMethod).to receive(:retrieve).with(stripe_payment_method_id).and_call_original
      expect_any_instance_of(StripeChargeablePaymentMethod).to receive(:prepare_for_direct_charge).and_call_original

      chargeable.prepare!

      expect(chargeable.stripe_charge_params[:payment_method]).to be_present
      expect(chargeable.stripe_charge_params[:payment_method]).not_to eq(stripe_payment_method_id)
    end
  end
end
