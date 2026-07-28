# frozen_string_literal: true

require "spec_helper"

# A local-currency quote is signed against a total the browser computes from the exchange rate
# that was in the page props when the checkout rendered. UpdateCurrenciesWorker rewrites that
# stored rate every hour, and purchase creation recomputes the canonical total at the charge-time
# rate, so a checkout left open across an hourly tick fails Checkout::BuyerCurrencyQuote.verify!
# with "total mismatch".
#
# Before this change the retry could not recover: the page rebuilt its products from the same
# in-memory cart, carrying the same stale rate, so every retry minted a token for the same
# rejected total and the buyer was stuck until they reloaded the page by hand. The checkout now
# re-fetches the cart props, adopts the server's current rate, and re-quotes — so the second Pay
# goes through.
describe "Buyer-currency quote recovery after the stored rate moves (#6484)", type: :system, js: true do
  include CurrencyHelper

  # The product is priced in EUR, which is what puts a render-time exchange rate into the page
  # props: CheckoutPresenter derives `exchange_rate` from the stored rate for the listed currency,
  # and the browser converts to canonical USD with it before posting.
  let(:render_time_eur_rate) { 0.9 }
  let(:charge_time_eur_rate) { 0.8 }

  # The buyer is Canadian. This matters for more than geography: a quote is deliberately withheld
  # when the product is already listed in the buyer's own currency, because quoting it would be a
  # round trip (listed €10 → canonical USD at our stored rate → back to EUR at Stripe's rate) that
  # lands a cent or two off the listed price. Checkout::BuyerCurrencyQuote#quotable_product?
  # returns false on that match. A French buyer of a euro listing would therefore be handed no
  # quote at all, the first Pay would simply succeed, and this spec could never reach the rejection
  # it exists to test. A Canadian buying a euro listing is the shape the fix is about.
  let(:canada) do
    GeoIp::Result.new(
      country_name: "Canada", country_code: "CA", region_name: "Quebec",
      city_name: "Montreal", postal_code: "H2X 1Y4", latitude: nil, longitude: nil
    )
  end

  before do
    allow(GeoIp).to receive(:lookup).and_return(canada)
    # Only the FX-quote boundary is stubbed; the surcharge request, the token, the display, and
    # the charge all run for real.
    allow(StripeFxQuote).to receive(:create).and_return(
      StripeFxQuote::Quote.new(id: "fxq_rate_refresh", expires_at: 30.minutes.from_now, fx_rate: BigDecimal("1.1"))
    )

    @original_eur_rate = currency_namespace.get("EUR")
    currency_namespace.set("EUR", render_time_eur_rate)

    @seller = create(:user_with_compliance_info, disable_buyer_local_currency: false)
    Feature.activate_user(:buyer_local_currency, @seller)
    Feature.activate_user(:buyer_currency_charging, @seller)
    # Rounding has its own spec; opting out keeps the totals here equal to the plain conversion so
    # this spec is only about which rate the retry uses.
    @seller.update!(disable_buyer_currency_rounding: true)
    @product = create(:product, user: @seller, price_cents: 10_00, price_currency_type: "eur")
  end

  after do
    currency_namespace.set("EUR", @original_eur_rate)
    Feature.deactivate_user(:buyer_local_currency, @seller)
    Feature.deactivate_user(:buyer_currency_charging, @seller)
  end

  it "refreshes the rate and completes the purchase on the retry instead of rejecting forever" do
    visit "/l/#{@product.unique_permalink}"
    add_to_cart(@product)

    # The quote currency comes from the GeoIP lookup (Canada), not the billing country, so
    # checking out with a US billing address keeps this spec off the EU-VAT and SCA paths while
    # still quoting in CAD. It also settles which postal field the form renders — the helper's
    # default "ZIP code" only exists for a US address.
    fill_checkout_form(@product, email: "buyer@example.com", country: "United States")

    # Stand in for the hourly UpdateCurrenciesWorker tick landing while this checkout is open.
    # The page keeps the rate it rendered with, so the total it has already signed no longer
    # matches what purchase creation will compute.
    currency_namespace.set("EUR", charge_time_eur_rate)

    # First attempt: the server refuses the quote and the checkout says so, without charging.
    expect do
      click_on "Pay", exact: true
      expect(page).to have_alert(text: "local-currency price", wait: 30)
    end.not_to change { @product.sales.successful.count }

    # Second attempt: the recovery has re-fetched the cart props and re-quoted on the current
    # rate, so the same click now succeeds.
    #
    # Wait for that fresh quote to land before clicking. The recovery deliberately puts surcharges
    # back into "pending" and re-requests them, and the reducer refuses to start a payment while
    # they are pending — the on-screen total is not yet one the charge would honour. Clicking in
    # that window is a no-op by design, so without this wait the spec asserts the retry failed when
    # really it never started.
    wait_for_checkout_surcharges_loaded

    expect do
      click_on "Pay", exact: true
      expect(page).to have_alert(text: "Your purchase was successful!", visible: :all, wait: 60)
    end.to change { @product.sales.successful.count }.by(1)

    purchase = @product.sales.successful.last
    # The charge went through at the refreshed rate, which is the whole point: a purchase created
    # on the stale rate would carry the pre-tick USD total (€10.00 at 0.9 is US$11.11, at 0.8 it
    # is US$12.50). One cent of tolerance keeps this off float-rounding trivia.
    expect(purchase.total_transaction_cents).to be_within(1).of((10_00 / charge_time_eur_rate).round)
    expect(purchase.total_transaction_cents).not_to be_within(1).of((10_00 / render_time_eur_rate).round)
  end
end
