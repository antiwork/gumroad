# frozen_string_literal: true

require "spec_helper"

# Changing currency invalidates the quote, and the control that changes it lives inside the
# summary the invalidation blanks. These examples pin the interaction that keeps the two from
# fighting: the picker stays on screen through the round trip, the summary says it is working,
# and a currency the cart cannot be quoted in is named rather than silently swapped.
describe "Buyer-currency checkout currency picker", type: :system, js: true do
  let(:france) do
    GeoIp::Result.new(
      country_name: "France", country_code: "FR", region_name: "IDF",
      city_name: "Paris", postal_code: "75001", latitude: nil, longitude: nil
    )
  end
  def quote(fx_rate, delay_seconds: 0)
    # A delay at the FX-quote boundary is what makes the re-quote window observable rather than a
    # race; everything between the buyer's click and this call runs for real.
    sleep delay_seconds if delay_seconds.positive?
    StripeFxQuote::Quote.new(id: "fxq_picker_test", expires_at: 30.minutes.from_now, fx_rate: BigDecimal(fx_rate))
  end

  before do
    allow(GeoIp).to receive(:lookup).and_return(france)
    # The seller charges on the Gumroad platform account, and the FX quote is minted against the
    # account's Stripe id — spelled out here so the lane does not depend on how the shared account
    # happens to be seeded.
    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)&.tap do |account|
      account.update!(charge_processor_merchant_id: "acct_gumroad", currency: Currency::USD)
    end || create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_gumroad", currency: Currency::USD)
    @seller = create(:user_with_compliance_info, disable_buyer_local_currency: false)
    Feature.activate_user(:buyer_local_currency, @seller)
    Feature.activate_user(:buyer_currency_charging, @seller)
    # Rounding is off so the totals below are the plain conversions. Checkout::PresentmentRounding
    # has its own spec.
    @seller.update!(disable_buyer_currency_rounding: true)
    @product = create(:product, user: @seller, price_cents: 10_00)
  end

  after do
    Feature.deactivate_user(:buyer_local_currency, @seller)
    Feature.deactivate_user(:buyer_currency_charging, @seller)
  end

  it "keeps the picker and the total on screen while the chosen currency is quoted" do
    # US$10.00 at 1.25 USD per EUR is €8.00; at 1.00 USD per GBP it is £10.00.
    allow(StripeFxQuote).to receive(:create) { quote("1.25") }

    visit "/l/#{@product.unique_permalink}"
    add_to_cart(@product)
    expect(page).to have_text("Total €8", normalize_ws: true)

    allow(StripeFxQuote).to receive(:create) { quote("1.0", delay_seconds: 2) }
    select "£ (British Pounds)", from: "Currency"

    # The control the buyer just used is still there, still holding their choice, and the
    # summary says why the amount under it has not moved yet.
    expect(page).to have_text("Updating total…")
    expect(page).to have_select("Currency", selected: "£ (British Pounds)")
    expect(page).to have_text("Total", normalize_ws: true)

    expect(page).to have_text("Total £10", normalize_ws: true)
    expect(page).to have_no_text("Updating total…")
  end

  it "names a currency the cart cannot be quoted in instead of switching the total quietly" do
    # The learned-mismatch marker would land on the shared Gumroad platform account, which a
    # js: true example does not roll back — it would suppress this currency for later examples.
    allow_any_instance_of(MerchantAccount).to receive(:record_settlement_currency_mismatch!)
    allow(StripeFxQuote).to receive(:create) do |from_currency:, **_args|
      raise StripeFxQuote::SettlementCurrencyMismatch, from_currency if from_currency == Currency::GBP

      quote("1.25")
    end

    visit "/l/#{@product.unique_permalink}"
    add_to_cart(@product)
    expect(page).to have_text("Total €8", normalize_ws: true)

    select "£ (British Pounds)", from: "Currency"

    expect(page).to have_text("We can't charge this cart in £ (British Pounds)")
    expect(page).to have_select("Currency", selected: "€ (Euro) — detected")
    expect(page).to have_text("Total €8", normalize_ws: true)
  end
end
