# frozen_string_literal: true

require "spec_helper"

describe StripeChargeIntent, :vcr do
  include StripeChargesHelper

  let(:processor_payment_intent) do
    create_stripe_payment_intent(StripePaymentMethodHelper.success.to_stripejs_payment_method_id,
                                 amount: 1_00,
                                 currency: "usd")
  end

  subject (:stripe_charge_intent) { described_class.new(payment_intent: processor_payment_intent) }

  describe "#id" do
    it "returns the ID of Stripe payment intent" do
      expect(stripe_charge_intent.id).to eq(processor_payment_intent.id)
    end
  end

  describe "#client_secret" do
    it "returns the client secret of Stripe payment intent" do
      expect(stripe_charge_intent.client_secret).to eq(processor_payment_intent.client_secret)
    end
  end

  context "when Stripe payment intent requires confirmation" do
    let(:stripe_payment_method_id) { StripePaymentMethodHelper.success.to_stripejs_payment_method_id }
    let(:processor_payment_intent) do
      params = {
        payment_method: stripe_payment_method_id,
        payment_method_types: ["card"],
        amount: 1_00,
        currency: "usd"
      }
      Stripe::PaymentIntent.create(params)
    end

    it "is not successful" do
      expect(stripe_charge_intent.succeeded?).to eq(false)
    end

    it "requires confirmation" do
      expect(stripe_charge_intent.payment_intent.status == StripeIntentStatus::REQUIRES_CONFIRMATION).to eq(true)
    end

    it "does not load the charge" do
      expect(ChargeProcessor).not_to receive(:get_charge)

      expect(stripe_charge_intent.charge).to be_blank
    end
  end

  context "when Stripe payment intent is successful" do
    let(:stripe_payment_method_id) { StripePaymentMethodHelper.success.to_stripejs_payment_method_id }
    let(:processor_payment_intent) do
      create_stripe_payment_intent(stripe_payment_method_id, amount: 1_00, currency: "usd")
    end

    before do
      processor_payment_intent.confirm
    end

    it "is successful" do
      expect(stripe_charge_intent.succeeded?).to eq(true)
    end

    it "does not require action" do
      expect(stripe_charge_intent.requires_action?).to eq(false)
    end

    it "loads the charge" do
      expect(stripe_charge_intent.charge.id).to eq(processor_payment_intent.latest_charge)
    end
  end

  context "when Stripe payment intent is not successful" do
    let(:processor_payment_intent) do
      create_stripe_payment_intent(nil,
                                   amount: 1_00,
                                   currency: "usd")
    end

    it "is not successful" do
      expect(stripe_charge_intent.succeeded?).to eq(false)
    end

    it "does not require action" do
      expect(stripe_charge_intent.requires_action?).to eq(false)
    end

    it "does not load the charge" do
      expect(ChargeProcessor).not_to receive(:get_charge)

      expect(stripe_charge_intent.charge).to be_blank
    end
  end

  context "when Stripe payment intent is canceled" do
    let(:processor_payment_intent) do
      payment_intent = create_stripe_payment_intent(StripePaymentMethodHelper.success.to_stripejs_payment_method_id,
                                                    amount: 1_00,
                                                    currency: "usd")
      ChargeProcessor.cancel_payment_intent!(MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id), payment_intent.id)
    end

    it "is canceled" do
      expect(stripe_charge_intent.canceled?).to eq(true)
    end

    it "is not successful" do
      expect(stripe_charge_intent.succeeded?).to eq(false)
    end

    it "does not require action" do
      expect(stripe_charge_intent.requires_action?).to eq(false)
    end

    it "does not load the charge" do
      expect(ChargeProcessor).not_to receive(:get_charge)

      expect(stripe_charge_intent.charge).to be_blank
    end
  end

  context "when Stripe payment intent requires action" do
    let(:stripe_payment_method_id) { StripePaymentMethodHelper.success_with_sca.to_stripejs_payment_method_id }
    let(:processor_payment_intent) do
      create_stripe_payment_intent(stripe_payment_method_id, amount: 1_00, currency: "usd")
    end

    before do
      processor_payment_intent.confirm
    end

    it "is not successful" do
      expect(stripe_charge_intent.succeeded?).to eq(false)
    end

    it "requires action" do
      expect(stripe_charge_intent.requires_action?).to eq(true)
    end

    it "does not load the charge" do
      expect(ChargeProcessor).not_to receive(:get_charge)

      expect(stripe_charge_intent.charge).to be_blank
    end

    context "when next action type is unsupported" do
      before do
        allow(processor_payment_intent.next_action).to receive(:type).and_return "redirect_to_url"
      end

      it "notifies us via Bugsnag" do
        expect(Bugsnag).to receive(:notify).with(/requires an unsupported action/)
        described_class.new(payment_intent: processor_payment_intent)
      end
    end
  end
end
