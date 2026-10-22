# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe Products::BulkPricesController do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_seller) }
  let!(:product_a) { create(:product, user: seller, price_cents: 500) }
  let!(:product_b) { create(:product, user: seller, price_cents: 700) }
  let!(:other_product) { create(:product, price_cents: 900) }

  include_context "with user signed in as admin for seller"

  def post_prices(ids, price)
    post :create, params: { ids:, price: }, as: :json
  end

  it "sets one price on every selected product" do
    post_prices([product_a.unique_permalink, product_b.unique_permalink], "9.99")

    expect(response.parsed_body).to include("success" => true, "updated" => 2)
    expect(product_a.reload.price_cents).to eq(999)
    expect(product_b.reload.price_cents).to eq(999)
  end

  it "does not touch another seller's product and reports it" do
    post_prices([product_a.unique_permalink, other_product.unique_permalink], "3")

    expect(response.parsed_body["updated"]).to eq(1)
    expect(response.parsed_body["results"].find { _1["id"] == other_product.unique_permalink }).to include("updated" => false)
    expect(other_product.reload.price_cents).to eq(900)
  end

  it "skips tiered memberships and keeps their price" do
    membership = create(:membership_product, user: seller)
    before = membership.reload.default_price_cents

    post_prices([membership.unique_permalink, product_a.unique_permalink], "4")

    expect(response.parsed_body["updated"]).to eq(1)
    expect(membership.reload.default_price_cents).to eq(before)
  end

  it "rejects an invalid price without changing anything" do
    post_prices([product_a.unique_permalink], "abc")

    expect(response).to have_http_status(:unprocessable_entity)
    expect(product_a.reload.price_cents).to eq(500)
  end

  it "reports a price below the currency minimum" do
    post_prices([product_a.unique_permalink], "0.10")

    expect(response.parsed_body["updated"]).to eq(0)
    expect(product_a.reload.price_cents).to eq(500)
  end

  it "rejects an empty selection" do
    post_prices([], "5")
    expect(response).to have_http_status(:unprocessable_entity)
  end
end
