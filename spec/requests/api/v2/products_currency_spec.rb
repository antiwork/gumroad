# frozen_string_literal: true

require "spec_helper"

describe "Products API currency normalization", type: :request do
  let(:seller) { create(:user) }
  let(:oauth_application) { create(:oauth_application, owner: create(:user)) }
  let(:token) { create("doorkeeper/access_token", application: oauth_application, resource_owner_id: seller.id, scopes: "edit_products") }

  before do
    host! "test.gumroad.com"
  end

  it "accepts uppercase price_currency_type when creating a product" do
    post "/api/v2/products",
         params: { access_token: token.token, name: "ZAR workbook", price: 21_999, price_currency_type: "ZAR" }

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/json")
    expect(response.parsed_body).to include("success" => true)
    expect(seller.links.last.price_currency_type).to eq("zar")
  end

  it "accepts uppercase price_currency_type when updating a product" do
    product = create(:product, user: seller, price_currency_type: "zar", price_cents: 21_999)

    put "/api/v2/products/#{product.external_id}",
        params: { access_token: token.token, name: "Renamed workbook", price_currency_type: "ZAR" }

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/json")
    expect(response.parsed_body).to include("success" => true)
    expect(product.reload).to have_attributes(name: "Renamed workbook", price_currency_type: "zar")
  end

  it "accepts a price_currency_type with surrounding whitespace" do
    post "/api/v2/products",
         params: { access_token: token.token, name: "Padded workbook", price: 21_999, price_currency_type: " ZAR " }

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/json")
    expect(response.parsed_body).to include("success" => true)
    expect(seller.links.last.price_currency_type).to eq("zar")
  end

  it "rejects an explicitly blank price_currency_type instead of using the seller's default" do
    seller.update!(currency_type: "eur")

    post "/api/v2/products",
         params: { access_token: token.token, name: "Blank currency", price: 21_999, price_currency_type: "   " }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      "success" => false,
      "message" => "'   ' is not a supported currency."
    )
    expect(seller.links.count).to eq(0)
  end

  it "uses the seller's default currency when price_currency_type is omitted" do
    seller.update!(currency_type: "eur")

    post "/api/v2/products",
         params: { access_token: token.token, name: "Default currency", price: 21_999 }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("success" => true)
    expect(seller.links.last.price_currency_type).to eq("eur")
  end

  it "changes the display currency when price and currency are sent together" do
    product = create(:product, user: seller, price_currency_type: "usd", price_cents: 9_900)

    put "/api/v2/products/#{product.external_id}",
        params: { access_token: token.token, price: 9_900, price_currency_type: "eur" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("success" => true)
    expect(product.reload.price_currency_type).to eq("eur")
    expect(product.default_price_cents).to eq(9_900)
    expect(product.prices.alive.where(currency: "eur").last.price_cents).to eq(9_900)
  end

  it "changes the display currency when only the currency is sent, carrying the existing amount" do
    product = create(:product, user: seller, price_currency_type: "usd", price_cents: 9_900)

    put "/api/v2/products/#{product.external_id}",
        params: { access_token: token.token, price_currency_type: "eur" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("success" => true)
    expect(product.reload.price_currency_type).to eq("eur")
    expect(product.default_price_cents).to eq(9_900)
  end

  it "applies the sent price to the new currency rather than the old one" do
    product = create(:product, user: seller, price_currency_type: "usd", price_cents: 9_900)

    put "/api/v2/products/#{product.external_id}",
        params: { access_token: token.token, price: 4_500, price_currency_type: "eur" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("success" => true)
    expect(product.reload.price_currency_type).to eq("eur")
    expect(product.default_price_cents).to eq(4_500)
    expect(product.prices.alive.where(currency: "usd").last.price_cents).to eq(9_900)
  end

  it "changes the display currency of a bundle" do
    product = create(:product, :bundle, user: seller, price_currency_type: "usd", price_cents: 9_900)

    put "/api/v2/products/#{product.external_id}",
        params: { access_token: token.token, price_currency_type: "eur" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("success" => true)
    expect(product.reload.price_currency_type).to eq("eur")
    expect(product.default_price_cents).to eq(9_900)
  end

  it "changes the price without touching the currency when no currency is sent" do
    product = create(:product, user: seller, price_currency_type: "eur", price_cents: 9_900)

    put "/api/v2/products/#{product.external_id}",
        params: { access_token: token.token, price: 4_500 }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("success" => true)
    expect(product.reload.price_currency_type).to eq("eur")
    expect(product.default_price_cents).to eq(4_500)
  end

  it "names the currency the caller actually sent when rejecting it" do
    post "/api/v2/products",
         params: { access_token: token.token, name: "Bad currency", price: 21_999, price_currency_type: "ZZZ" }

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/json")
    expect(response.parsed_body).to include(
      "success" => false,
      "message" => "'ZZZ' is not a supported currency."
    )
  end
end
