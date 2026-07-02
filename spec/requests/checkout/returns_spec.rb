# frozen_string_literal: true

require "spec_helper"

describe "Checkout return page", :vcr, type: :request do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 10_00) }
  let(:line_item) { { uid: "unique-id-0", permalink: product.unique_permalink, perceived_price_cents: product.price_cents, quantity: 1 } }
  let(:order_params) do
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
    host! DOMAIN
    MerchantAccount.find_or_create_by!(user_id: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id) do |ma|
      ma.charge_processor_alive_at = Time.current
    end
    Rack::Attack.enabled = false
  end

  after do
    Rack::Attack.enabled = true
  end

  def build_client_confirmed_order(line_items: [line_item])
    order, = Order::CreateService.new(params: order_params.merge(line_items:)).perform
    purchases = order.purchases.to_a
    purchases.each { _1.resolve_merchant_account_and_recompute_fees!(StripeChargeProcessor.charge_processor_id) }
    merchant_account = purchases.first.merchant_account
    amount_cents = purchases.sum(&:total_transaction_cents)
    gumroad_amount_cents = purchases.sum(&:total_transaction_amount_for_gumroad_cents)

    charge = order.charges.create!(seller:, merchant_account:, processor: merchant_account.charge_processor_id,
                                   amount_cents:, gumroad_amount_cents:)
    purchases.each { _1.update!(charge:) }

    charge_intent = StripeDeferredPaymentIntent.create(
      merchant_account:, amount_cents:, amount_for_gumroad_cents: gumroad_amount_cents,
      reference: "#{Charge::COMBINED_CHARGE_PREFIX}#{charge.external_id}",
      description: "Gumroad Charge #{charge.external_id}",
      statement_description: seller.name_or_username,
      transfer_group: charge.id_with_prefix,
      idempotency_key: "deferred_intent_test_#{SecureRandom.hex}",
      payment_method_types: Checkout::StripePaymentPresenter::CLIENT_CONFIRM_PAYMENT_METHOD_TYPES,
      currency: Checkout::StripePaymentPresenter::CLIENT_CONFIRM_CURRENCY
    )
    charge.update!(stripe_payment_intent_id: charge_intent.id)
    purchases.each { _1.create_processor_payment_intent!(intent_id: charge_intent.id) }
    [order, charge]
  end

  def visit_return_page(order, payment_intent:)
    token = order.secure_external_id(scope: "confirm", expires_at: 1.hour.from_now)
    get checkout_return_path(token, payment_intent:)
  end

  context "when the payment intent succeeded" do
    it "finalizes the order, sends receipts, and redirects to the content page with the receipt notice" do
      order, charge = build_client_confirmed_order
      Stripe::PaymentIntent.confirm(charge.stripe_payment_intent_id, { payment_method: "pm_card_visa" })
      purchase = order.purchases.first

      expect do
        visit_return_page(order, payment_intent: charge.stripe_payment_intent_id)
      end.to change { SendChargeReceiptJob.jobs.size }.by(1)

      expect(purchase.reload).to be_successful
      expect(purchase.stripe_transaction_id).to be_present
      expect(charge.reload.processor_transaction_id).to be_present
      expect(Event.purchase.where(purchase_id: purchase.id).count).to eq(1)
      expect(purchase.url_redirect).to be_present
      expect(response).to redirect_to("#{purchase.url_redirect.download_page_url}?receipt=true")
    end

    it "finalizes exactly once when the page is revisited" do
      order, charge = build_client_confirmed_order
      Stripe::PaymentIntent.confirm(charge.stripe_payment_intent_id, { payment_method: "pm_card_visa" })
      purchase = order.purchases.first

      visit_return_page(order, payment_intent: charge.stripe_payment_intent_id)
      succeeded_at = purchase.reload.succeeded_at

      visit_return_page(order, payment_intent: charge.stripe_payment_intent_id)

      expect(purchase.reload.succeeded_at).to eq(succeeded_at)
      expect(Event.purchase.where(purchase_id: purchase.id).count).to eq(1)
      expect(response).to redirect_to("#{purchase.url_redirect.download_page_url}?receipt=true")
    end

    context "when the order has multiple items" do
      let(:second_product) { create(:product, user: seller, price_cents: 15_00) }
      let(:second_line_item) { { uid: "unique-id-1", permalink: second_product.unique_permalink, perceived_price_cents: second_product.price_cents, quantity: 1 } }

      it "finalizes every purchase and redirects to the product page" do
        order, charge = build_client_confirmed_order(line_items: [line_item, second_line_item])
        Stripe::PaymentIntent.confirm(charge.stripe_payment_intent_id, { payment_method: "pm_card_visa" })

        visit_return_page(order, payment_intent: charge.stripe_payment_intent_id)

        expect(order.purchases.reload).to all(be_successful)
        expect(response).to redirect_to(order.purchases.first.link.long_url)
      end
    end
  end

  context "when the payment intent is still processing" do
    it "renders the pending page without fulfilling" do
      order, charge = build_client_confirmed_order
      purchase = order.purchases.first
      charge_intent = instance_double(StripeChargeIntent, succeeded?: false, processing?: true)
      allow(ChargeProcessor).to receive(:get_charge_intent)
        .with(charge.merchant_account, charge.stripe_payment_intent_id)
        .and_return(charge_intent)

      expect do
        visit_return_page(order, payment_intent: charge.stripe_payment_intent_id)
      end.not_to change { SendChargeReceiptJob.jobs.size }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Checkout/Returns/Pending")
      expect(purchase.reload).to be_in_progress
      expect(purchase.stripe_status).to eq(StripeIntentStatus::PROCESSING)
    end
  end

  context "when the payment was not completed" do
    it "fails the purchases and sends the buyer back to checkout to retry" do
      order, charge = build_client_confirmed_order
      purchase = order.purchases.first

      visit_return_page(order, payment_intent: charge.stripe_payment_intent_id)

      expect(purchase.reload).to be_failed
      expect(response).to redirect_to(checkout_path)
      expect(flash[:alert]).to be_present
    end

    it "restores the cart that was deleted when the order was created" do
      cart = create(:cart, :guest, browser_guid: order_params[:browser_guid])
      order, charge = build_client_confirmed_order
      expect(cart.reload).not_to be_alive

      visit_return_page(order, payment_intent: charge.stripe_payment_intent_id)

      expect(cart.reload).to be_alive
      expect(response).to redirect_to(checkout_path)
    end

    it "leaves the cart deleted when the buyer already has a newer alive cart" do
      cart = create(:cart, :guest, browser_guid: order_params[:browser_guid])
      order, charge = build_client_confirmed_order
      newer_cart = create(:cart, :guest, browser_guid: order_params[:browser_guid])

      visit_return_page(order, payment_intent: charge.stripe_payment_intent_id)

      expect(cart.reload).not_to be_alive
      expect(newer_cart.reload).to be_alive
    end
  end

  context "when the order token is invalid" do
    it "responds with 404" do
      get checkout_return_path("invalid-token", payment_intent: "pi_123")

      expect(response).to have_http_status(:not_found)
    end
  end

  context "when the payment_intent param does not match the order's charge" do
    it "responds with 404 without touching the purchases" do
      order, charge = build_client_confirmed_order
      purchase = order.purchases.first

      visit_return_page(order, payment_intent: "pi_mismatched")

      expect(response).to have_http_status(:not_found)
      expect(purchase.reload).to be_in_progress
      expect(charge.reload.processor_transaction_id).to be_nil
    end
  end

  context "when the order has no client-confirmed charge" do
    it "responds with 404" do
      order, = Order::CreateService.new(params: order_params).perform

      visit_return_page(order, payment_intent: "pi_123")

      expect(response).to have_http_status(:not_found)
    end
  end
end
