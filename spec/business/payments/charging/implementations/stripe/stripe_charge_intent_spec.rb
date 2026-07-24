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

  it "does not retry loading the charge when flow of funds is not available yet" do
    payment_intent = Stripe::PaymentIntent.construct_from(
      id: "pi_success",
      status: StripeIntentStatus::SUCCESS,
      latest_charge: "ch_success"
    )
    processor_charge = BaseProcessorCharge.new
    processor_charge.id = "ch_success"
    charge_processor = instance_double(StripeChargeProcessor)

    expect(StripeChargeProcessor).to receive(:new).once.and_return(charge_processor)
    expect(charge_processor).to receive(:get_charge).once.with("ch_success", merchant_account: nil).and_return(processor_charge)

    expect(described_class.new(payment_intent:).charge).to eq(processor_charge)
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
        allow(processor_payment_intent.next_action).to receive(:type).and_return "boleto_display_details"
      end

      it "notifies error tracker" do
        expect(ErrorNotifier).to receive(:notify).with(/requires an unsupported action/)
        described_class.new(payment_intent: processor_payment_intent)
      end
    end

    context "when next action type is handled by Stripe.js in the browser" do
      before do
        allow(processor_payment_intent.next_action).to receive(:type).and_return "cashapp_handle_redirect_or_display_qr_code"
      end

      it "does not notify error tracker" do
        expect(ErrorNotifier).not_to receive(:notify)
        described_class.new(payment_intent: processor_payment_intent)
      end

      it "does not report the action as supported by the server-driven flow" do
        expect(described_class.new(payment_intent: processor_payment_intent).requires_action?).to eq(false)
      end
    end

    context "when next action type is a browser-handled redirect (iDEAL/Klarna abandoned on the provider's site)" do
      before do
        allow(processor_payment_intent.next_action).to receive(:type).and_return "redirect_to_url"
        allow(processor_payment_intent).to receive(:payment_method_types).and_return %w[card klarna]
        # The attempted method — not just the offered menu — is what keys the suppression:
        # the buyer picked Klarna and Stripe.js owns the provider redirect.
        allow(processor_payment_intent).to receive(:payment_method).and_return Stripe::StripeObject.construct_from(type: "klarna")
      end

      it "does not notify error tracker" do
        expect(ErrorNotifier).not_to receive(:notify)
        described_class.new(payment_intent: processor_payment_intent)
      end

      it "does not report the action as supported by the server-driven flow" do
        expect(described_class.new(payment_intent: processor_payment_intent).requires_action?).to eq(false)
      end
    end

    context "when next action type is redirect_to_url on an intent without a client-redirect method (no browser owns the redirect)" do
      before do
        allow(processor_payment_intent.next_action).to receive(:type).and_return "redirect_to_url"
        # The intent carries only the payment method's ID (a plain retrieve doesn't expand
        # it), so the validation resolves the attempted method — the SCA helper's card —
        # with a real (recorded) targeted PaymentMethod retrieve.
      end

      it "notifies error tracker" do
        expect(ErrorNotifier).to receive(:notify).with(/requires an unsupported action/)
        described_class.new(payment_intent: processor_payment_intent)
      end
    end

    context "when next action type is redirect_to_url and the attempted method (resolved via a PaymentMethod retrieve) is card, even though the offered menu includes a client-redirect method" do
      before do
        allow(processor_payment_intent.next_action).to receive(:type).and_return "redirect_to_url"
        allow(processor_payment_intent).to receive(:payment_method_types).and_return %w[card klarna]
        # payment_method stays the unexpanded ID string a plain retrieve returns; the
        # validation resolves the real attempted type — the SCA helper's card — via a real
        # (recorded) PaymentMethod retrieve instead of silently falling back to the offered
        # menu (which would wrongly swallow a stray redirect on the card path).
      end

      it "still notifies error tracker — a stray redirect on the card path must keep alerting" do
        expect(ErrorNotifier).to receive(:notify).with(/requires an unsupported action/)
        described_class.new(payment_intent: processor_payment_intent)
      end
    end

    context "when next action type is redirect_to_url and the attempted-method lookup fails" do
      before do
        allow(processor_payment_intent.next_action).to receive(:type).and_return "redirect_to_url"
        # The menu offers a client-redirect method (as nearly every US intent does via
        # cashapp), so the OLD nil-and-fall-back behavior would have swallowed the alert.
        allow(processor_payment_intent).to receive(:payment_method_types).and_return %w[card klarna cashapp]
        allow(Stripe::PaymentMethod).to receive(:retrieve)
          .and_raise(Stripe::APIConnectionError.new("stripe is down"))
      end

      it "still notifies error tracker — a lookup failure must not degrade to the menu fallback and silence the alert during a Stripe outage" do
        # Two notifies: the lookup failure itself, then the unsupported-action alert.
        expect(ErrorNotifier).to receive(:notify).with(instance_of(Stripe::APIConnectionError), anything)
        expect(ErrorNotifier).to receive(:notify).with(/requires an unsupported action/)
        described_class.new(payment_intent: processor_payment_intent)
      end
    end

    context "when next action type is redirect_to_url on a direct-Connect merchant's intent" do
      let(:connect_merchant_account) do
        create(:merchant_account_stripe_connect, charge_processor_merchant_id: "acct_connect_klarna")
      end

      before do
        allow(processor_payment_intent.next_action).to receive(:type).and_return "redirect_to_url"
        allow(processor_payment_intent).to receive(:payment_method_types).and_return %w[card klarna]
      end

      it "scopes the attempted-method retrieve to the connected account — payment methods created there are invisible from the platform" do
        # Pin the derivation itself: StripeChargeIntent must pass the connected account's ID
        # through to the lookup, or direct-Connect Klarna sellers' abandoned redirects would
        # fail the lookup (and page) every time.
        expect(Stripe::PaymentMethod).to receive(:retrieve)
          .with(processor_payment_intent.payment_method, { stripe_account: "acct_connect_klarna" })
          .and_return(Stripe::StripeObject.construct_from(id: processor_payment_intent.payment_method, type: "klarna"))
        expect(ErrorNotifier).not_to receive(:notify)

        described_class.new(payment_intent: processor_payment_intent, merchant_account: connect_merchant_account)
      end
    end
  end
end
