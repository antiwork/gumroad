# frozen_string_literal: true

require "spec_helper"
require "business/payments/charging/chargeable_protocol"
require "business/payments/charging/implementations/stripe/stripe_chargeable_common_shared_examples"

describe StripeChargeableCreditCard, :vcr do
  let(:user) { create(:user) }
  let(:original_chargeable) { build(:chargeable) }
  let(:original_chargeable_reusable_token) do
    original_chargeable.prepare!
    original_chargeable.reusable_token_for!(StripeChargeProcessor.charge_processor_id, user)
  end

  let(:chargeable) do
    StripeChargeableCreditCard.new(
      nil,
      original_chargeable_reusable_token,
      original_chargeable.payment_method_id,
      original_chargeable.fingerprint,
      original_chargeable.stripe_setup_intent_id,
      original_chargeable.stripe_payment_intent_id,
      original_chargeable.last4,
      original_chargeable.number_length,
      original_chargeable.visual,
      original_chargeable.expiry_month,
      original_chargeable.expiry_year,
      original_chargeable.card_type,
      original_chargeable.country,
      original_chargeable.zip_code
    )
  end

  it_should_behave_like "a chargeable"

  include_examples "stripe chargeable common"

  describe "#reusable_token!" do
    it "returns persistable token" do
      chargeable.prepare!

      expect(chargeable.reusable_token!(user)).to eq original_chargeable_reusable_token
    end
  end

  describe "#stripe_charge_params" do
    it "returns customer and payment method" do
      chargeable.prepare!

      expect(chargeable.stripe_charge_params).to eq({ customer: original_chargeable.reusable_token_for!(StripeChargeProcessor.charge_processor_id, nil),
                                                      payment_method: original_chargeable.payment_method_id })
    end
  end

  describe "#charge!" do
    describe "when merchant account is not a stripe connect account" do
      let(:merchant_account) { MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) }
      let(:chargeable) do
        StripeChargeableCreditCard.new(
          merchant_account,
          original_chargeable_reusable_token,
          original_chargeable.payment_method_id,
          original_chargeable.fingerprint,
          original_chargeable.stripe_setup_intent_id,
          original_chargeable.stripe_payment_intent_id,
          original_chargeable.last4,
          original_chargeable.number_length,
          original_chargeable.visual,
          original_chargeable.expiry_month,
          original_chargeable.expiry_year,
          original_chargeable.card_type,
          original_chargeable.country,
          original_chargeable.zip_code
        )
      end

      it "charges using the credit card payment method id" do
        expect_any_instance_of(StripeChargeableCreditCard).not_to receive(:prepare_for_direct_charge)

        chargeable.prepare!

        expect(chargeable.reusable_token!(user)).to eq original_chargeable_reusable_token
        expect(chargeable.stripe_charge_params[:customer]).to eq original_chargeable_reusable_token
        expect(chargeable.stripe_charge_params[:payment_method]).to eq original_chargeable.payment_method_id
      end

      it "retrieves payment method id if it is not present" do
        expect_any_instance_of(StripeChargeableCreditCard).not_to receive(:prepare_for_direct_charge)

        chargeable = StripeChargeableCreditCard.new(
          merchant_account,
          original_chargeable_reusable_token,
          nil,
          original_chargeable.fingerprint,
          original_chargeable.stripe_setup_intent_id,
          original_chargeable.stripe_payment_intent_id,
          original_chargeable.last4,
          original_chargeable.number_length,
          original_chargeable.visual,
          original_chargeable.expiry_month,
          original_chargeable.expiry_year,
          original_chargeable.card_type,
          original_chargeable.country,
          original_chargeable.zip_code
        )

        chargeable.prepare!

        expect(chargeable.reusable_token!(user)).to eq original_chargeable_reusable_token
        expect(chargeable.stripe_charge_params[:customer]).to eq original_chargeable_reusable_token
        expect(chargeable.stripe_charge_params[:payment_method]).to eq original_chargeable.payment_method_id
      end

      it "charges the payment method on gumroad stripe account" do
        expect(Stripe::PaymentIntent).to receive(:create).with(hash_including({ amount: 100,
                                                                                currency: "usd",
                                                                                description: "test description",
                                                                                metadata: { purchase: "reference" },
                                                                                transfer_group: nil,
                                                                                confirm: true,
                                                                                payment_method_types: ["card"],
                                                                                off_session: true,
                                                                                setup_future_usage: nil,
                                                                                customer: original_chargeable_reusable_token,
                                                                                payment_method: original_chargeable.payment_method_id })).and_call_original

        chargeable.prepare!

        StripeChargeProcessor.new.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 0_30, "reference", "test description")
      end
    end

    describe "when merchant account is a stripe connect account" do
      let(:merchant_account) { create(:merchant_account_stripe_connect) }
      let(:chargeable) do
        StripeChargeableCreditCard.new(
          merchant_account,
          original_chargeable_reusable_token,
          original_chargeable.payment_method_id,
          original_chargeable.fingerprint,
          original_chargeable.stripe_setup_intent_id,
          original_chargeable.stripe_payment_intent_id,
          original_chargeable.last4,
          original_chargeable.number_length,
          original_chargeable.visual,
          original_chargeable.expiry_month,
          original_chargeable.expiry_year,
          original_chargeable.card_type,
          original_chargeable.country,
          original_chargeable.zip_code
        )
      end

      it "charges using the cloned payment method" do
        expect_any_instance_of(StripeChargeableCreditCard).to receive(:prepare_for_direct_charge).and_call_original

        chargeable.prepare!

        expect(chargeable.reusable_token!(user)).to eq original_chargeable_reusable_token
        expect(chargeable.stripe_charge_params[:customer]).not_to eq original_chargeable_reusable_token
        expect(chargeable.stripe_charge_params[:payment_method]).not_to eq original_chargeable.payment_method_id
      end

      it "charges the payment method cloned on the connected stripe account" do
        chargeable.prepare!

        expect(Stripe::PaymentIntent).to receive(:create).with(hash_including({ amount: 100,
                                                                                currency: "usd",
                                                                                description: "test description",
                                                                                metadata: { purchase: "reference" },
                                                                                transfer_group: nil,
                                                                                payment_method_types: ["card"],
                                                                                confirm: true,
                                                                                off_session: true,
                                                                                setup_future_usage: nil,
                                                                                payment_method: chargeable.stripe_charge_params[:payment_method],
                                                                                application_fee_amount: 24 }), { stripe_account: merchant_account.charge_processor_merchant_id }).and_call_original

        StripeChargeProcessor.new.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 0_30, "reference", "test description")
      end

      context "when saved credit card only has a customer ID and no payment method ID" do
        let(:merchant_account) { create(:merchant_account_stripe_connect) }
        let(:chargeable) do
          StripeChargeableCreditCard.new(
            merchant_account,
            original_chargeable_reusable_token,
            nil,
            original_chargeable.fingerprint,
            original_chargeable.stripe_setup_intent_id,
            original_chargeable.stripe_payment_intent_id,
            original_chargeable.last4,
            original_chargeable.number_length,
            original_chargeable.visual,
            original_chargeable.expiry_month,
            original_chargeable.expiry_year,
            original_chargeable.card_type,
            original_chargeable.country,
            original_chargeable.zip_code
          )
        end

        it "retrieves the payment method associated with the customer and clones it" do
          expect_any_instance_of(StripeChargeableCreditCard).to receive(:prepare_for_direct_charge).and_call_original

          chargeable.prepare!

          expect(chargeable.reusable_token!(user)).to eq original_chargeable_reusable_token
          expect(chargeable.payment_method_id).to eq original_chargeable.payment_method_id
          expect(chargeable.stripe_charge_params[:customer]).not_to eq original_chargeable_reusable_token
          expect(chargeable.stripe_charge_params[:payment_method]).not_to eq original_chargeable.payment_method_id
        end

        it "charges the payment method cloned on the connected stripe account" do
          chargeable.prepare!

          expect(Stripe::PaymentIntent).to receive(:create).with(hash_including({ amount: 100,
                                                                                  currency: "usd",
                                                                                  description: "test description",
                                                                                  metadata: { purchase: "reference" },
                                                                                  transfer_group: nil,
                                                                                  payment_method_types: ["card"],
                                                                                  confirm: true,
                                                                                  off_session: true,
                                                                                  setup_future_usage: nil,
                                                                                  payment_method: chargeable.stripe_charge_params[:payment_method],
                                                                                  application_fee_amount: 24 }), { stripe_account: merchant_account.charge_processor_merchant_id }).and_call_original

          StripeChargeProcessor.new.create_payment_intent_or_charge!(merchant_account, chargeable, 1_00, 0_30, "reference", "test description")
        end
      end
    end
  end
end
