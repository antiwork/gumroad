# frozen_string_literal: true

require "spec_helper"

# The price_currency_type column is nullable and the setter preserves blank
# input, so a legacy row can hold NULL. The public product page must render
# for it. The model reader must keep returning NULL for these rows: the
# NULL-safe SQL in Link.with_detached_default_offer_code mirrors the Ruby
# predicate, so the guards live in the presentation layer instead.
describe "product page with a NULL price_currency_type", type: :request do
  let(:seller) { create(:user, name: "Legacy Seller") }
  let(:product) { create(:product, user: seller) }

  before do
    # update_column bypasses the setter, matching a legacy NULL row.
    product.update_column(:price_currency_type, nil)
  end

  it "renders the standard product page with its structured data" do
    get "http://#{seller.subdomain}/l/#{product.unique_permalink}"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("application/ld+json")
  end
end
