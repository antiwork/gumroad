# frozen_string_literal: true

require("spec_helper")
require "timeout"

# Browser E2E for the Payment Element client-confirm path (Lane B). Lane A (stripejs_purchase_spec.rb)
# keeps Rails on the server-confirm charge path; Lane B inverts control: Rails builds an unconfirmed
# PaymentIntent (#prepare), the browser mints a ConfirmationToken from the real Payment Element iframe and
# confirms it client-side (stripe.confirmPayment, redirect: "if_required"), then Rails finalizes without
# re-charging (#finalize). Every other Lane B test stubs that browser seam (server-minted token,
# server-side confirm); this is the only test that drives the real three-endpoint handshake against live
# Stripe test mode, wiring Show.tsx -> startConfirmOrderCreation -> #prepare/confirm/#finalize together.
describe("PurchaseScenario using StripeJs client-confirm (Lane B)", type: :system, js: true) do
  # Mirrors the reader in stripejs_purchase_spec.rb: the presenter's chosen integration is serialized into
  # the Inertia page props, so we can prove Lane B (payment_element_confirm) was the path the frontend took.
  def checkout_payment_props
    page.evaluate_script(<<~JS)
      JSON.parse(document.querySelector("[data-page]").getAttribute("data-page")).props.checkout.checkout_payment
    JS
  end

  before do
    @seller = create(:user)
    # A seller with no merchant account falls back to the platform (Gumroad) Stripe account, so the token
    # mint, the client confirm, and the deferred intent all live on one account — the single-account
    # topology Lane B Phase 1 supports (connected-account scoping is a later phase).
    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
      create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_#{SecureRandom.hex(8)}")
    @product = create(:product_with_pdf_file, user: @seller, price_cents: 1000)
    Feature.activate_user(Checkout::StripePaymentPresenter::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, @seller)
    Feature.activate_user(Checkout::StripePaymentPresenter::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_FEATURE_NAME, @seller)
  end

  it "completes a card purchase through the client-confirm handshake, charging exactly once" do
    visit("/checkout?product=#{@product.unique_permalink}")

    checkout_payment = checkout_payment_props
    expect(checkout_payment["integration"]).to eq("payment_element_confirm")
    expect(checkout_payment["fallback_reason"]).to be_nil
    expect(page).to have_selector("iframe[src*='elements-inner-payment']")

    # Lane B never re-charges server-side, so Order::ChargeService (instantiated only by the Lane A
    # OrdersController#create path) must never run. Paired with the integration assertion above, this guards
    # against a silent regression to Lane A, which at the Purchase level is otherwise indistinguishable
    # (both yield a ch_ charge).
    expect(Order::ChargeService).not_to receive(:new)

    check_out(@product, payment_element: true)

    purchase = Purchase.last
    expect(purchase.successful?).to be(true)
    # Real ch_ charge id, written at finalize. In confirm mode for a no-connect seller the Payment Element
    # mounts on the platform account, so the browser-entered 4242 card is the one actually charged (no
    # payment-method swap, unlike the Lane A specs).
    expect(purchase.stripe_transaction_id).to match(/\Ach_/)
    expect(purchase.card_visual).to eq("**** **** **** 4242")
    # The intent -> order mapping is durable and written at prepare time: the unconfirmed PaymentIntent (pi_)
    # is stamped on the Charge and mirrored on a ProcessorPaymentIntent before the browser confirms.
    expect(purchase.processor_payment_intent).to be_present
    expect(purchase.processor_payment_intent.intent_id).to match(/\Api_/)
    expect(purchase.charge.stripe_payment_intent_id).to eq(purchase.processor_payment_intent.intent_id)
    expect(@product.sales.successful.count).to eq(1)
  end

  it "surfaces a decline and creates no successful purchase when the card is declined at client confirm" do
    visit("/checkout?product=#{@product.unique_permalink}")

    expect(checkout_payment_props["integration"]).to eq("payment_element_confirm")

    # Composed manually rather than via check_out(error:): a client-side confirmPayment decline never reaches
    # #finalize, so the built purchase is left in_progress — check_out(error:) asserts a *failed* purchase and a
    # sales.failed bump that this path does not produce (KTD4).
    fill_checkout_form(@product, credit_card: nil)
    fill_in_payment_element(number: "4000000000000002")
    click_on "Pay", exact: true

    # The decline flows through order.ts's confirmResult.error branch, which renders the Stripe message in the
    # checkout results (Receipt.tsx) without throwing — so it never hits the catch that logs console.error and
    # would trip JSErrorReporter. Exact Stripe copy is brittle, so assert the stable "declined" substring.
    expect(page).to have_text(/declined/i, wait: 60)
    expect(page).not_to have_alert(text: "Your purchase was successful!")

    expect(@product.sales.successful.count).to eq(0)
    leftover = @product.sales.last
    expect(leftover.purchase_state).to eq("in_progress")
    expect(leftover.stripe_transaction_id).to be_nil
  end
end
