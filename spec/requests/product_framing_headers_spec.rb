# frozen_string_literal: true

require "spec_helper"

# Sellers embed product pages in their own sites, so the standard product page must carry
# no framing headers. SecureHeaders opts X-Frame-Options out globally and leaves
# Referrer-Policy unset; only the custom-HTML path sets them (see
# RendersCustomHtmlPages#apply_custom_html_response_headers, covered in user_pages_spec).
# The wiring this depends on is asserted in spec/config/rails_default_headers_spec.rb.
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
