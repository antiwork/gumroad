# frozen_string_literal: true

require("spec_helper")
require "timeout"

# E2E coverage for the Payment Element client-confirm handshake against Stripe test mode.
describe("PurchaseScenario using StripeJs client-confirm", type: :system, js: true) do
  def checkout_payment_props
    page.evaluate_script(<<~JS)
      JSON.parse(document.querySelector("[data-page]").getAttribute("data-page")).props.checkout.checkout_payment
    JS
  end

  before do
    @seller = create(:user)
    # Keep token minting, client confirmation, and the deferred intent on the same Stripe account.
    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
      create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_#{SecureRandom.hex(8)}")
    @product = create(:product_with_pdf_file, user: @seller, price_cents: 1000)
    Feature.activate_user(Checkout::StripePaymentPresenter::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, @seller)
    Feature.activate_user(Checkout::StripePaymentPresenter::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_FEATURE_NAME, @seller)
  end

  it "completes a card purchase through the client-confirm handshake, charging exactly once" do
    visit("/checkout?product=#{@product.unique_permalink}")

    checkout_payment = checkout_payment_props
    expect(checkout_payment["integration"]).to eq("payment_element_client_confirm")
    expect(checkout_payment["fallback_reason"]).to be_nil
    expect(page).to have_selector("iframe[src*='elements-inner-payment']")

    # Both paths produce a ch_ charge, so assert this does not fall back to server-confirm.
    expect(Order::ChargeService).not_to receive(:new)

    check_out(@product, payment_element: true)

    purchase = Purchase.last
    expect(purchase.successful?).to be(true)
    # The platform-account Payment Element confirms the entered 4242 card directly.
    expect(purchase.stripe_transaction_id).to match(/\Ach_/)
    expect(purchase.card_visual).to eq("**** **** **** 4242")
    # The intent -> order mapping is durable and written at prepare time: the unconfirmed PaymentIntent (pi_)
    # is stamped on the Charge and mirrored on a ProcessorPaymentIntent before the browser confirms.
    expect(purchase.processor_payment_intent).to be_present
    expect(purchase.processor_payment_intent.intent_id).to match(/\Api_/)
    expect(purchase.charge.stripe_payment_intent_id).to eq(purchase.processor_payment_intent.intent_id)
    expect(@product.sales.successful.count).to eq(1)
  end

  it "completes a card purchase on a connected account through the client-confirm handshake" do
    @seller.update!(check_merchant_account_is_linked: true)
    connect_account = create(:merchant_account_stripe_connect, charge_processor_merchant_id: "acct_1SOb0DEwFhlcVS6d", user: @seller)

    visit("/checkout?product=#{@product.unique_permalink}")

    checkout_payment = checkout_payment_props
    expect(checkout_payment["integration"]).to eq("payment_element_client_confirm")
    expect(checkout_payment.dig("elements_options", "stripe_connect_account_id")).to eq(connect_account.charge_processor_merchant_id)
    expect(page).to have_selector("iframe[src*='elements-inner-payment']")

    expect(Order::ChargeService).not_to receive(:new)

    check_out(@product, payment_element: true)

    purchase = Purchase.last
    expect(purchase.successful?).to be(true)
    expect(purchase.merchant_account).to eq(connect_account)
    expect(purchase.stripe_transaction_id).to match(/\Ach_/)
    expect(purchase.processor_payment_intent.intent_id).to match(/\Api_/)
    expect(purchase.charge.stripe_payment_intent_id).to eq(purchase.processor_payment_intent.intent_id)
  end

  it "surfaces a decline and creates no successful purchase when the card is declined at client confirm" do
    visit("/checkout?product=#{@product.unique_permalink}")

    expect(checkout_payment_props["integration"]).to eq("payment_element_client_confirm")

    # Client-side confirm errors never reach #finalize, so the built purchase remains in_progress.
    fill_checkout_form(@product, credit_card: nil)
    fill_in_payment_element(number: "4000000000000002")
    click_on "Pay", exact: true

    # Exact Stripe copy is brittle; the stable substring proves the error rendered.
    expect(page).to have_text(/declined/i, wait: 60)
    expect(page).not_to have_alert(text: "Your purchase was successful!")

    expect(@product.sales.successful.count).to eq(0)
    leftover = @product.sales.last
    expect(leftover.purchase_state).to eq("in_progress")
    expect(leftover.stripe_transaction_id).to be_nil
  end

  it "completes an inline 3DS challenge under client-confirm and fulfills" do
    visit("/checkout?product=#{@product.unique_permalink}")

    expect(checkout_payment_props["integration"]).to eq("payment_element_client_confirm")

    # Covers confirmPayment rather than the older confirmCardPayment path.
    check_out(@product, payment_element: true, credit_card: { number: "4000002500003155" }, sca: true)

    purchase = Purchase.last
    expect(purchase.successful?).to be(true)
    expect(purchase.stripe_transaction_id).to match(/\Ach_/)
  end

  it "surfaces an authentication failure when the inline 3DS challenge is failed under client-confirm" do
    visit("/checkout?product=#{@product.unique_permalink}")

    expect(checkout_payment_props["integration"]).to eq("payment_element_client_confirm")

    fill_checkout_form(@product, credit_card: nil)
    fill_in_payment_element(number: "4000002500003155")
    click_on "Pay", exact: true

    within_sca_frame { click_on "Fail" }

    # A failed client-side challenge never reaches #finalize, so the purchase remains
    # in_progress and no charge lands.
    expect(page).to have_text(/authenticat/i, wait: 60)
    expect(@product.sales.successful.count).to eq(0)
    leftover = @product.sales.last
    expect(leftover.purchase_state).to eq("in_progress")
    expect(leftover.stripe_transaction_id).to be_nil
  end
end
