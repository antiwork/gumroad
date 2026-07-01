# frozen_string_literal: true

require "spec_helper"

describe Order::FinalizeConfirmedChargeService, :vcr do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 10_00) }
  let(:line_item) { { uid: "unique-id-0", permalink: product.unique_permalink, perceived_price_cents: product.price_cents, quantity: 1 } }
  let(:common_params) do
    {
      email: "buyer@example.com",
      cc_zipcode: "12345",
      purchase: {
        full_name: "Edgar Gumstein", street_address: "123 Gum Road",
        country: "US", state: "CA", city: "San Francisco", zip_code: "94117"
      },
      browser_guid: SecureRandom.uuid,
      ip_address: "0.0.0.0",
      session_id: "a107d0b7ab5ab3c1eeb7d3aaf9792977",
      is_mobile: false,
    }
  end

  before do
    # Keep the deferred intent and finalize call on the platform Stripe account.
    MerchantAccount.find_or_create_by!(user_id: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id) do |ma|
      ma.charge_processor_alive_at = Time.current
    end
  end

  def confirmation_token_id
    response = Stripe.raw_request(:post, "/v1/test_helpers/confirmation_tokens", { payment_method: "pm_card_visa" })
    Stripe.deserialize(response.http_body).id
  end

  # Builds an order and runs the prepare step, returning the order with an unconfirmed intent.
  def prepared_order
    params = { line_items: [line_item] }.merge(common_params)
    order, = Order::CreateService.new(params:).perform
    Order::PreparePaymentIntentService.new(order:, params:, confirmation_token: confirmation_token_id).perform
    order
  end

  def payment_intent_id(order)
    order.charges.find { _1.stripe_payment_intent_id.present? }.stripe_payment_intent_id
  end

  def cart_uid(purchase)
    "#{purchase.link.unique_permalink} #{purchase.variant_attributes.first&.external_id}"
  end

  context "when the browser has confirmed the intent" do
    it "finalizes the order without re-charging and is idempotent across repeated calls" do
      order = prepared_order
      Stripe::PaymentIntent.confirm(payment_intent_id(order), { payment_method: "pm_card_visa" })
      purchase = order.purchases.first

      responses = nil
      expect do
        responses = described_class.new(order:).perform
      end.to change { ActivateIntegrationsWorker.jobs.size }.by(1)

      expect(responses[cart_uid(purchase)][:success]).to be(true)
      expect(purchase.reload).to be_successful
      expect(purchase.stripe_transaction_id).to be_present
      # Client-confirm purchases derive buyer-facing card presentation from the
      # confirmed charge; without that finalize work these fields would be nil.
      expect(purchase.card_visual).to eq("**** **** **** 4242")
      expect(purchase.card_type).to eq("visa")
      expect(purchase.card_country).to eq("US")
      expect(order.charges.last.reload.processor_transaction_id).to be_present
      succeeded_at = purchase.succeeded_at

      # A second finalize (e.g. webhook after the AJAX call) must not fulfill again.
      second_responses = nil
      expect do
        second_responses = described_class.new(order:).perform
      end.not_to change { ActivateIntegrationsWorker.jobs.size }

      expect(second_responses[cart_uid(purchase)][:success]).to be(true)
      expect(purchase.reload).to be_successful
      expect(purchase.succeeded_at).to eq(succeeded_at)
    end
  end

  context "when the browser never confirmed the intent" do
    it "fails the purchase without fulfilling" do
      order = prepared_order
      purchase = order.purchases.first

      responses = described_class.new(order:).perform

      expect(responses[cart_uid(purchase)][:success]).to be(false)
      expect(purchase.reload).to be_failed
    end
  end

  context "when the intent is still processing" do
    it "marks the purchase pending without fulfilling" do
      order = prepared_order
      purchase = order.purchases.first
      processing_intent = StripeChargeIntent.new(
        payment_intent: Stripe::PaymentIntent.construct_from(id: payment_intent_id(order), status: "processing")
      )
      allow(ChargeProcessor).to receive(:get_charge_intent).and_return(processing_intent)

      responses = described_class.new(order:).perform

      expect(responses[cart_uid(purchase)][:processing]).to be(true)
      expect(purchase.reload).to be_in_progress
      expect(purchase.stripe_status).to eq("processing")
      expect(purchase.successful?).to be(false)
    end
  end

  context "when no charge with a payment intent exists" do
    it "reports every purchase as processing rather than an empty resubmittable success" do
      params = { line_items: [line_item] }.merge(common_params)
      order, = Order::CreateService.new(params:).perform
      purchase = order.purchases.first

      responses = described_class.new(order:).perform

      expect(responses[cart_uid(purchase)][:success]).to be(true)
      expect(responses[cart_uid(purchase)][:processing]).to be(true)
      expect(purchase.reload).to be_in_progress
    end
  end
end
