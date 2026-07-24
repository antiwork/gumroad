# frozen_string_literal: true

require "spec_helper"

# Browser-level regression for the UPI billing-details prefill (PR #6191 review).
#
# The unit tests assert React passes the right defaultValues to the Payment Element, but only a
# real browser proves the MOUNTED element applies them: Stripe pushes option updates into its
# iframe via element.update(), and a regression in that handoff (or in which name source feeds
# the prefill) is invisible to a mocked <PaymentElement>. The reviewed bug: the prefill read the
# Link contact snapshot, which deliberately freezes once the buyer touches the element — so a
# buyer who clicked the Card row first and THEN typed their name switched to UPI and found
# Stripe's Name field empty, forced to retype a name checkout already knew.
describe "UPI Payment Element billing prefill", type: :system, js: true do
  let(:india) do
    GeoIp::Result.new(
      country_name: "India", country_code: "IN", region_name: "KA",
      city_name: "Bengaluru", postal_code: "560001", latitude: nil, longitude: nil
    )
  end

  before do
    allow(GeoIp).to receive(:lookup).and_return(india)
    @seller = create(:user_with_compliance_info, disable_buyer_local_currency: false)
    Feature.activate_user(Checkout::StripePaymentPresenter::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, @seller)
    Feature.activate_user(Checkout::StripePaymentPresenter::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_FEATURE_NAME, @seller)
    Feature.activate_user(:buyer_local_currency, @seller)
    Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, @seller)
    # Test mode offers local methods unrestricted, but activate the launch flag anyway so the
    # spec mirrors the production configuration this guards.
    Feature.activate_user(:checkout_local_method_upi, @seller)
    # Keep token minting and the deferred intent on the same Stripe account.
    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
      create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_#{SecureRandom.hex(8)}")
    @product = create(:product_with_pdf_file, user: @seller, price_currency_type: Currency::INR, price_cents: 149_900)
  end

  after do
    Feature.deactivate_user(Checkout::StripePaymentPresenter::STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, @seller)
    Feature.deactivate_user(Checkout::StripePaymentPresenter::STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_FEATURE_NAME, @seller)
    Feature.deactivate_user(:buyer_local_currency, @seller)
    Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, @seller)
    Feature.deactivate_user(:checkout_local_method_upi, @seller)
  end

  it "carries a name typed after touching the element into the mounted UPI pane" do
    visit("/checkout?product=#{@product.unique_permalink}")

    # The INR method-forced element mounts with the flat accordion as the payment-method
    # selector — there must be no outer "Card" radio row duplicating the element's own rows.
    expect(page).to have_selector("iframe[src*='elements-inner-payment']", wait: 20)
    expect(page).to have_no_selector("input[type='radio'][aria-label='Card']")

    # Touch the element first (the reviewed repro): interacting with the element freezes the
    # Link contact-prefill snapshot, which must NOT be the source feeding the UPI pane.
    within_payment_element_frame do
      first(:fillable_field, "Card number", visible: false, wait: 20).click
    end

    # THEN type the name into checkout's own Full name field (visible while Card is selected).
    fill_in "Full name", with: "Priya Prefill Test"

    # Switch to UPI inside the element's accordion.
    within_payment_element_frame do
      find("label", text: "UPI", visible: false, wait: 20).click
    end

    # Checkout's own Full name field hides for the UPI selection (the pane collects it)...
    expect(page).to have_no_field("Full name")

    # ...and the MOUNTED pane's Name field must open prefilled with the just-typed name —
    # not empty (the reviewed bug), proving Stripe applied the defaultValues update.
    within_payment_element_frame do
      name_field = first(:fillable_field, "Full name", visible: false, wait: 20) ||
        first(:fillable_field, "Name", visible: false, wait: 20)
      expect(name_field).to be_present
      expect(name_field.value).to eq("Priya Prefill Test")
    end
  end
end
