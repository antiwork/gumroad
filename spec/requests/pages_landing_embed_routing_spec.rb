# frozen_string_literal: true

require "spec_helper"

# Full-stack routing check: the landing iframe endpoint must resolve on the
# seller subdomain, where custom_html products render after the show redirect.
# A controller spec can't catch this — it bypasses routing.
describe "GET /l/:id/landing/embed routing", type: :request do
  let(:seller) { create(:user, username: "landingseller") }
  let(:product) { create(:product, user: seller, custom_html: "<section><h1>Live</h1></section>") }

  before { Feature.activate_user(:custom_html_pages, seller) }

  it "resolves on the seller subdomain and serves the seller's HTML" do
    host = URI.parse(seller.subdomain_with_protocol).host
    get "/l/#{product.unique_permalink}/landing/embed", headers: { "HOST" => host }

    expect(response).to be_successful
    expect(response.body).to include("<h1>Live</h1>")
  end
end
