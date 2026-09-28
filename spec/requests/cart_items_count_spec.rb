# frozen_string_literal: true

require "spec_helper"

# WebKit grants a frame storage access only when it is same-origin with the page, so a seller
# subdomain now serves the count itself; a custom domain cannot read the root domain's cookie and
# keeps using the root-domain route.
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
end
