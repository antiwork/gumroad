# frozen_string_literal: true

require "spec_helper"

describe StripeDeferredPaymentIntent do
  let(:amount_cents) { 1_00 }
  let(:amount_for_gumroad_cents) { 30 }
  let(:reference) { "deferred-intent-reference" }
  let(:idempotency_key) { "deferred-intent-spec-key" }

  def create_deferred_intent(**overrides)
    described_class.create(
      merchant_account: nil,
      amount_cents:,
      amount_for_gumroad_cents:,
      reference:,
      description: "Test product",
      idempotency_key:,
      **overrides
    )
  end

  # The core deferred-intent contract is exercised against the platform account (no connected
  # account), mirroring how StripeChargeIntent specs create intents directly on the platform.
  describe ".create on the platform account", :vcr do
    it "creates an unconfirmed PaymentIntent with automatic payment methods and no redirects" do
      charge_intent = create_deferred_intent

      expect(charge_intent).to be_a(StripeChargeIntent)
      payment_intent = charge_intent.payment_intent
      expect(payment_intent.status).to eq("requires_payment_method")
      expect(payment_intent.automatic_payment_methods.enabled).to eq(true)
      expect(payment_intent.automatic_payment_methods.allow_redirects).to eq("never")
      expect(payment_intent.confirmation_method).to eq("automatic")
      expect(charge_intent.client_secret).to be_present
    end

    it "does not attach a payment method or charge the buyer" do
      charge_intent = create_deferred_intent

      expect(charge_intent.payment_intent.payment_method).to be_nil
      expect(charge_intent.succeeded?).to eq(false)
      expect(charge_intent.payment_intent.latest_charge).to be_nil
    end

    it "reuses the same intent when called again with the same idempotency key" do
      first = create_deferred_intent
      second = create_deferred_intent

      expect(second.id).to eq(first.id)
    end
  end

  # Fee routing is pure request construction; asserting the built params avoids needing a live
  # connected account per branch (the direct-charge round-trip is covered end-to-end in U12).
  describe ".create fee routing" do
    let(:captured_params) { [] }

    before do
      allow(Stripe::PaymentIntent).to receive(:create) do |params, opts = {}|
        captured_params << { params:, opts: }
        Stripe::PaymentIntent.construct_from(id: "pi_deferred_test", status: "requires_payment_method",
                                             client_secret: "pi_deferred_test_secret")
      end
    end

    it "passes the idempotency key as a Stripe request option" do
      create_deferred_intent

      expect(captured_params.last[:opts][:idempotency_key]).to eq(idempotency_key)
    end

    it "routes a Gumroad-managed account through a destination transfer" do
      seller = create(:user)
      merchant_account = create(:merchant_account, user: seller, charge_processor_merchant_id: "acct_managed")

      described_class.create(merchant_account:, amount_cents: 1_000, amount_for_gumroad_cents: 300,
                             reference:, description: "x", idempotency_key:)

      params = captured_params.last[:params]
      expect(params[:transfer_data]).to eq(destination: "acct_managed", amount: 700)
      expect(params).not_to have_key(:application_fee_amount)
      expect(captured_params.last[:opts]).not_to have_key(:stripe_account)
    end

    it "routes a connected direct-charge account through an application fee on that account" do
      seller = create(:user)
      merchant_account = create(:merchant_account_stripe_connect, user: seller)

      described_class.create(merchant_account:, amount_cents: 1_000, amount_for_gumroad_cents: 300,
                             reference:, description: "x", idempotency_key:)

      params = captured_params.last[:params]
      expect(params[:application_fee_amount]).to eq(300)
      expect(params).not_to have_key(:transfer_data)
      expect(captured_params.last[:opts][:stripe_account]).to eq(merchant_account.charge_processor_merchant_id)
    end

    it "keeps everything on the platform account when there is no merchant account" do
      create_deferred_intent

      params = captured_params.last[:params]
      expect(params).not_to have_key(:transfer_data)
      expect(params).not_to have_key(:application_fee_amount)
      expect(captured_params.last[:opts]).not_to have_key(:stripe_account)
    end

    it "never confirms the intent" do
      expect_any_instance_of(Stripe::PaymentIntent).not_to receive(:confirm)

      create_deferred_intent
    end
  end
end
