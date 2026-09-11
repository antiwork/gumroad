# frozen_string_literal: true

require "spec_helper"

# Sellers embed public product pages, so they must omit framing headers; custom-HTML
# pages set them (RendersCustomHtmlPages#apply_custom_html_response_headers, user_pages_spec).
describe "framing headers on a public product page", type: :request do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }

  it "omits X-Frame-Options and Referrer-Policy" do
    get "http://#{seller.subdomain}/l/#{product.unique_permalink}"

    expect(response).to have_http_status(:ok)
    expect(response.headers["X-Frame-Options"]).to be_nil
    expect(response.headers["Referrer-Policy"]).to be_nil
  end
end
