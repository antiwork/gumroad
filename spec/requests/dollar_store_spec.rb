# frozen_string_literal: true

require "spec_helper"

describe "GET /dollar-store", type: :request do
  let(:seller) { create(:compliant_user) }

  let!(:cheap_product) { create(:product, :recommendable, user: seller, name: "fifty cent thing", price_cents: 50) }
  let!(:dollar_product) { create(:product, :recommendable, user: seller, name: "exactly one dollar", price_cents: 100) }
  let!(:expensive_product) { create(:product, :recommendable, user: seller, name: "five dollar thing", price_cents: 500) }
  let!(:free_product) { create(:product, :recommendable, user: seller, name: "free thing", price_cents: 0) }
  let!(:adult_product) { create(:product, :recommendable, user: seller, name: "adult cheap thing", price_cents: 50, is_adult: true) }

  before do
    host! DOMAIN
    Link.import(refresh: true, force: true)
  end

  def fetch_products(params = {})
    get "/dollar-store", params: params, headers: { "X-Inertia" => "true" }
    expect(response).to be_successful
    JSON.parse(response.body)["props"]["search_results"]["products"]
  end

  it "responds successfully" do
    get "/dollar-store"
    expect(response).to have_http_status(:ok)
  end

  it "renders the DollarStore Inertia component" do
    get "/dollar-store", headers: { "X-Inertia" => "true" }
    expect(JSON.parse(response.body)["component"]).to eq("DollarStore")
  end

  it "includes products priced at or below one dollar plus free products and excludes more expensive products" do
    product_ids = fetch_products.map { |p| p["id"] }
    expect(product_ids).to include(cheap_product.external_id, dollar_product.external_id, free_product.external_id)
    expect(product_ids).not_to include(expensive_product.external_id)
  end

  context "with adult products" do
    it "excludes adult products for users without the NSFW preference" do
      product_ids = fetch_products.map { |p| p["id"] }
      expect(product_ids).not_to include(adult_product.external_id)
    end
  end

end
