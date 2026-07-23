# frozen_string_literal: true

require "spec_helper"

describe StripeSetupIntent, :vcr do
  include StripeChargesHelper

  let(:processor_setup_intent) { create_stripe_setup_intent(StripePaymentMethodHelper.success.to_stripejs_payment_method_id) }

  subject (:stripe_setup_intent) { described_class.new(processor_setup_intent) }

  describe "#id" do
    it "returns the ID of Stripe setup intent" do
      expect(stripe_setup_intent.id).to eq(processor_setup_intent.id)
    end
  end

  describe "#client_secret" do
    it "returns the client secret of Stripe setup intent" do
      expect(stripe_setup_intent.client_secret).to eq(processor_setup_intent.client_secret)
    end
  end

  context "when Stripe setup intent is successful" do
    let(:processor_setup_intent) do
      create_stripe_setup_intent(StripePaymentMethodHelper.success.to_stripejs_payment_method_id)
    end

    it "is successful" do
      expect(stripe_setup_intent.succeeded?).to eq(true)
    end

    it "does not require action" do
      expect(stripe_setup_intent.requires_action?).to eq(false)
    end
  end

  context "when Stripe payment intent is not successful" do
    let(:processor_setup_intent) do
      create_stripe_setup_intent(nil, confirm: false)
    end

    it "is not successful" do
      expect(stripe_setup_intent.succeeded?).to eq(false)
    end

    it "does not require action" do
      expect(stripe_setup_intent.requires_action?).to eq(false)
    end
  end

  context "when Stripe payment intent is canceled" do
    let(:processor_setup_intent) do
      setup_intent = create_stripe_setup_intent(StripePaymentMethodHelper.success.to_stripejs_payment_method_id, confirm: false)
      ChargeProcessor.cancel_setup_intent!(MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id), setup_intent.id)
    end

    it "is canceled" do
      expect(stripe_setup_intent.canceled?).to eq(true)
    end

    it "is not successful" do
      expect(stripe_setup_intent.succeeded?).to eq(false)
    end

    it "does not require action" do
      expect(stripe_setup_intent.requires_action?).to eq(false)
    end
  end

  context "when Stripe payment intent requires action" do
    let(:processor_setup_intent) do
      create_stripe_setup_intent(StripePaymentMethodHelper.success_with_sca.to_stripejs_payment_method_id)
    end

    it "is not successful" do
      expect(stripe_setup_intent.succeeded?).to eq(false)
    end

    it "requires action" do
      expect(stripe_setup_intent.requires_action?).to eq(true)
    end

    context "when next action type is unsupported" do
      before do
        allow(processor_setup_intent.next_action).to receive(:type).and_return "boleto_display_details"
      end

      it "notifies error tracker" do
        expect(ErrorNotifier).to receive(:notify).with(/requires an unsupported action/)
        described_class.new(processor_setup_intent)
      end
    end

    context "when next action type is handled by Stripe.js in the browser" do
      before do
        allow(processor_setup_intent.next_action).to receive(:type).and_return "cashapp_handle_redirect_or_display_qr_code"
      end

      it "does not notify error tracker" do
        expect(ErrorNotifier).not_to receive(:notify)
        described_class.new(processor_setup_intent)
      end
    end

    context "when next action type is a browser-handled redirect" do
      before do
        # Force the requires_action + redirect_to_url shape directly: a bare SetupIntent.create
        # (no confirm) sits in requires_confirmation, so the validation under test would
        # otherwise never run (the check would pass vacuously).
        allow(processor_setup_intent).to receive_messages(
          status: StripeIntentStatus::REQUIRES_ACTION,
          next_action: double(type: "redirect_to_url"),
          payment_method_types: %w[card klarna]
        )
      end

      it "does not notify error tracker" do
        expect(ErrorNotifier).not_to receive(:notify)
        described_class.new(processor_setup_intent)
      end
    end

    context "when next action type is redirect_to_url on an intent without a client-redirect method (no browser owns the redirect)" do
      before do
        # Force the requires_action + redirect_to_url shape directly: a bare SetupIntent.create
        # (no confirm) sits in requires_confirmation, so the validation under test would
        # otherwise never run. payment_method_types stays the helper's card-only default.
        allow(processor_setup_intent).to receive_messages(
          status: StripeIntentStatus::REQUIRES_ACTION,
          next_action: double(type: "redirect_to_url")
        )
      end

      it "notifies error tracker" do
        expect(ErrorNotifier).to receive(:notify).with(/requires an unsupported action/)
        described_class.new(processor_setup_intent)
      end
    end
  end
end
