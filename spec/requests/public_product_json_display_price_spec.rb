# frozen_string_literal: true

require "spec_helper"

describe "GET /l/:permalink.json display_price" do
  let(:seller) { create(:user, disable_buyer_local_currency: false) }
  let!(:product) { create(:product, user: seller, price_cents: 1400) }

  before do
    allow(Feature).to receive(:active?).and_call_original
    allow(Feature).to receive(:active?).with(:buyer_local_currency, seller).and_return(true)
    allow(Feature).to receive(:active?).with(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller).and_return(false)
    allow(Feature).to receive(:active?).with(Checkout::BuyerCurrencyEligibility::SUBSCRIPTION_FEATURE_NAME, seller).and_return(false)
    allow_any_instance_of(Pages::ProductPrices).to receive(:buyer_local_currency_rate).and_return(BigDecimal("0.8"))
  end

  it "localizes from ?currency= and is never cacheable" do
    get "/l/#{product.unique_permalink}.json", params: { currency: "eur" }, headers: { "HTTP_HOST" => URI(product.long_url).host }

    body = response.parsed_body
    expect(response).to be_successful
    expect(body["display_price"]).to include("price" => "€11.20", "currency_code" => "eur", "localized" => true)
    expect(body["price_cents"]).to eq(1400)
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.headers["Cache-Control"]).to include("private")
  end
end
