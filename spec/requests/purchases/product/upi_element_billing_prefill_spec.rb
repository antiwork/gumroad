# frozen_string_literal: true

require "spec_helper"

# Browser-level regression for the UPI billing-details handling (PR #6191 review).
#
# The unit tests assert React hands the right options to the Payment Element, but only a real
# browser proves how the MOUNTED element behaves. The reviewed bug: the UPI pane originally
# collected the buyer's name itself and was prefilled via defaultValues — but Stripe applies
# defaultValues only when a field FIRST renders, so a name typed into checkout before switching
# to UPI never reached the pane and the buyer had to retype it (a defaultValues update pushed
# via element.update() to an already-selected pane does nothing — verified against the mounted
# element). The fix keeps the Full name field on checkout's own form for UPI and pins the
# pane's name field to "never"; this spec locks in that shape on the real element.
describe "UPI Payment Element billing handling", type: :system, js: true do
  def checkout_payment_props
    page.evaluate_script(<<~JS)
      JSON.parse(document.querySelector("[data-page]").getAttribute("data-page")).props.checkout_payment
    JS
  end

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

  it "keeps checkout's Full name field for UPI and has the pane collect only the address" do
    visit("/l/#{@product.unique_permalink}")
    add_to_cart(@product)

    # Guard the premise first: this cart must mount the INR method-forced element with UPI
    # offered — if the surface fell back, the assertions below would vacuously pass against
    # the wrong element.
    checkout_payment = checkout_payment_props
    expect(checkout_payment["integration"]).to eq("payment_element_client_confirm")
    expect(checkout_payment["fallback_reason"]).to be_nil
    expect(checkout_payment.dig("elements_options", "payment_method_types")).to include("upi")

    # The INR method-forced element mounts with the flat accordion as the payment-method
    # selector — there must be no outer "Card" radio row duplicating the element's own rows.
    expect(page).to have_selector("iframe[src*='elements-inner-payment']", wait: 20)
    expect(page).to have_no_selector("input[type='radio'][aria-label='Card']")

    # Stripe's element only RENDERS the UPI row on accounts enrolled in the UPI preview —
    # Gumroad's own test-mode account is enrolled (the preview apps render UPI), but a CI
    # sandbox may not be: the intent config above carries "upi" yet the element draws
    # card-only. Skip rather than fail on such accounts.
    upi_renders = within_payment_element_frame do
      page.has_xpath?(".//*[normalize-space(text())='UPI']", visible: :all, wait: 10)
    end
    skip "Stripe account not enrolled in the UPI element preview — cannot render the UPI row" unless upi_renders

    # The reviewed repro: the buyer touches the element FIRST (clicks the Card row's number
    # field), then types their name into checkout's own Full name field...
    #
    # Which accordion pane opens on mount is Stripe's choice, not ours, and for this INR/India
    # element it is not stable — UPI can come up expanded, with no Card number field at all.
    # Open Card when it isn't already the expanded row.
    within_payment_element_frame do
      unless has_selector?(:fillable_field, "Card number", visible: false, wait: 0)
        first(:xpath, ".//*[normalize-space(text())='Card']", visible: :all, wait: 20).click
      end
      first(:fillable_field, "Card number", visible: false, wait: 20).click
    end
    fill_in "Full name", with: "Priya Prefill Test"

    # ...then switches to UPI inside the element's accordion.
    within_payment_element_frame do
      find(:xpath, ".//*[normalize-space(text())='UPI']", visible: :all, wait: 20).click
    end

    # Checkout's own Full name field must STAY visible with the typed name intact — name is
    # checkout's field for every selection (the original design moved it into the pane, where
    # the typed name could never follow — see the file header).
    expect(page).to have_field("Full name", with: "Priya Prefill Test")
    # Checkout's Country selector hides for the selection: the pane collects the address.
    expect(page).to have_no_select("Country")

    # And the pane's own fields: the address form renders (Stripe requires a full street
    # address to confirm UPI), but NO name field — the pane must not ask for a name checkout
    # already collected. Assert on the pane's visible labels: Stripe's internal input ids/names
    # are not a stable contract.
    within_payment_element_frame do
      expect(page).to have_text("Address line 1", wait: 20)
      expect(page).to have_no_text("Full name")
    end
  end
end
