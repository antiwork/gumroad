# frozen_string_literal: true

require "spec_helper"

# The buyer-presentment charge path excludes save-card checkouts (setup_future_charges) in
# PR 1, so the checkout UI must only display locked buyer-currency totals when the charge
# will actually be made in that currency (issue #5419).
describe "Buyer-currency checkout save-card fallback (#5419)", type: :system, js: true do
  let(:france) do
    GeoIp::Result.new(
      country_name: "France", country_code: "FR", region_name: "IDF",
      city_name: "Paris", postal_code: "75001", latitude: nil, longitude: nil
    )
  end

  before do
    allow(GeoIp).to receive(:lookup).and_return(france)
    # The locked quote is stubbed at the FX-quote boundary; the rest of the flow
    # (surcharge request, token, display, charge) runs for real. The rate is USD per
    # EUR, so the US$10.00 product locks to €8.00.
    allow(StripeFxQuote).to receive(:create).and_return(
      StripeFxQuote::Quote.new(id: "fxq_system_test", expires_at: 30.minutes.from_now, fx_rate: BigDecimal("1.25"))
    )
    @seller = create(:user_with_compliance_info, disable_buyer_local_currency: false)
    Feature.activate_user(:buyer_local_currency, @seller)
    Feature.activate_user(:buyer_currency_charging, @seller)
    @product = create(:product, user: @seller, price_cents: 10_00)
  end

  after do
    Feature.deactivate_user(:buyer_local_currency, @seller)
    Feature.deactivate_user(:buyer_currency_charging, @seller)
  end

  context "when a logged-in buyer keeps the default save-card checkbox" do
    before do
      @buyer = create(:user)
    end

    it "shows canonical USD totals, flips to the locked EUR quote only while not saving, and charges the displayed USD amount" do
      login_as @buyer
      visit "/l/#{@product.unique_permalink}"
      add_to_cart(@product, logged_in_user: @buyer)

      # The quote currency comes from the GeoIP lookup (France), not the billing country;
      # checking out with a US billing address keeps this off the EU-VAT and SCA paths.
      check_out(@product, logged_in_user: @buyer, country: "United States") do
        # Saving the card forces the canonical charge path, so the checkout must not
        # display the locked EUR total it would never charge.
        expect(page).to have_checked_field("Save card for future purchases")
        expect(page).to have_text("Total US$10", normalize_ws: true)
        expect(page).to have_no_text("€")

        uncheck "Save card for future purchases"
        expect(page).to have_text("Total €8.00", normalize_ws: true)

        check "Save card for future purchases"
        expect(page).to have_text("Total US$10", normalize_ws: true)
        expect(page).to have_no_text("€")
      end

      purchase = Purchase.successful.last
      expect(purchase.link_id).to eq(@product.id)
      expect(purchase.total_transaction_cents).to eq(10_00)
      expect(purchase.purchase_presentment).to be_nil
      expect(ChargePresentment.count).to eq(0)
      expect(PurchasePresentment.count).to eq(0)
    end
  end

  context "when a guest checks out" do
    it "shows the locked EUR totals because guest checkouts cannot save the card" do
      visit "/l/#{@product.unique_permalink}"
      add_to_cart(@product)

      expect(page).to have_text("Total €8.00", normalize_ws: true)
      expect(page).to have_no_field("Save card for future purchases")
    end
  end
end
