# frozen_string_literal: true

require "spec_helper"

# A seller subdomain shares the root domain's cart cookie, so it serves the count to the page's own
# request; a custom domain cannot read that cookie and keeps the root-domain frame.
describe "Cart items count on a storefront host", type: :request do
  let(:seller) { create(:user, username: "countseller") }
  let(:browser_guid) { "cart-count-browser-guid" }

  before { host! seller.subdomain }

  def inertia_props(url)
    get url, headers: { "X-Inertia" => "true" }
    expect(response).to be_successful
    JSON.parse(response.body).fetch("props")
  end

  it "counts the buyer's alive cart products when the frame loads from the seller's subdomain" do
    cart = create(:cart, :guest, browser_guid:)
    create_list(:cart_product, 2, cart:)
    cookies[:_gumroad_guid] = browser_guid

    expect(inertia_props("/cart_items_count")["cart_items_count"]).to eq(2)
  end

  it "reports zero for an empty cart on the subdomain" do
    expect(inertia_props("/cart_items_count")["cart_items_count"]).to eq(0)
  end

  it "still serves the count on the root domain" do
    expect(inertia_props("#{PROTOCOL}://#{ROOT_DOMAIN}/cart_items_count")["cart_items_count"]).to eq(0)
  end

  it "serves the count as JSON to the page's own request on the subdomain" do
    cart = create(:cart, :guest, browser_guid:)
    create(:cart_product, cart:)
    cookies[:_gumroad_guid] = browser_guid

    get "/cart_items_count", headers: { "Accept" => "application/json" }

    expect(response).to be_successful
    expect(response.parsed_body["cart_items_count"]).to eq(1)
  end
end
