# frozen_string_literal: true

require "spec_helper"

describe "MCP server product search" do
  before do
    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
      create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_#{SecureRandom.hex(8)}")

    @connected_seller = create(:user)
    @seller = create(:recommendable_user, name: "Ada")
    @app = create(:oauth_application, owner: create(:user))
    @product = create(:product, :recommendable, user: @seller, name: "Learn to draw faces", price_cents: 1500)
    create(:product, :recommendable, user: create(:recommendable_user, name: "Grace"), name: "Watercolour for beginners", price_cents: 900)
    Link.import(refresh: true, force: true)
  end

  def call_tool(arguments, scopes: "view_public")
    token = create("doorkeeper/access_token", application: @app, resource_owner_id: @connected_seller.id, scopes:)
    payload = { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "search_products", arguments: } }
    post "/muse/v1/mcp", params: payload.to_json, headers: {
      "CONTENT_TYPE" => "application/json", "HOST" => DOMAIN, "ACCEPT" => "application/json",
      "Authorization" => "Bearer #{token.token}"
    }
    response.parsed_body
  end

  it "finds products sold by someone else, and marks the referrer on the link" do
    body = call_tool({ query: "draw" })

    products = body.dig("result", "structuredContent", "products")
    found = products.find { _1["name"] == "Learn to draw faces" }
    expect(found).to be_present
    expect(found).to include("price_cents" => 1500, "currency" => "usd", "seller_name" => "Ada")
    referrer = Rack::Utils.parse_query(URI.parse(found["url"]).query)["referrer"]
    expect(referrer).to eq("#{PROTOCOL}://#{DOMAIN}/mcp")
    expect(URI.parse(found["url"]).path).to include(@product.general_permalink)
  end

  it "finds a product whose seller is not the connected creator" do
    names = call_tool({ query: "watercolour" }).dig("result", "structuredContent", "products").map { _1["name"] }

    expect(names).to include("Watercolour for beginners")
  end

  it "asks for the public scope it needs" do
    body = call_tool({ query: "draw" }, scopes: "view_sales")

    expect(body.dig("error", "message")).to include("view_public")
  end

  it "lets a full-account token search too" do
    body = call_tool({ query: "draw" }, scopes: "account")

    expect(body.dig("result", "structuredContent", "products").map { _1["name"] }).to include("Learn to draw faces")
  end

  it "leaves out a hit whose product or seller changed since the last reindex" do
    fresh = create(:product, :recommendable, name: "Sketching faces")
    unpublished = create(:product, :recommendable, name: "Sketching unpublished")
    deleted = create(:product, :recommendable, name: "Sketching deleted")
    banned = create(:product, :recommendable, name: "Sketching banned")
    flagged = create(:product, :recommendable, name: "Sketching flagged")
    suspended = create(:product, :recommendable, user: create(:recommendable_user, name: "Mallory"), name: "Sketching suspended")
    stale = [unpublished, deleted, banned, flagged, suspended]
    Link.import(refresh: true, force: true)

    unpublished.update_column(:purchase_disabled_at, Time.current)
    deleted.update_column(:deleted_at, Time.current)
    banned.update_column(:banned_at, Time.current)
    flagged.update_column(:flags, flagged.flags | Link.flag_mapping["flags"][:is_adult])
    suspended.user.update_column(:user_risk_state, "suspended_for_fraud")
    expect(Link.search(Link.search_options(query: "sketching", size: 25)).records.map(&:id)).to include(fresh.id, *stale.map(&:id))
    expect(flagged.reload).to be_rated_as_adult

    names = call_tool({ query: "sketching" }).dig("result", "structuredContent", "products").map { _1["name"] }

    expect(names).to include("Sketching faces")
    expect(names).not_to include(*stale.map(&:name))
  end

  it "quotes the price a shopper pays after the seller's automatic sale" do
    seller = create(:recommendable_user, name: "Linus")
    create(:product, :recommendable, user: seller, name: "Ink wash on sale", price_cents: 2000)
    seller.offer_codes.create!(code: "HALF", amount_percentage: 50, universal: true, products: [], auto_apply: true)
    Link.import(refresh: true, force: true)

    found = call_tool({ query: "ink wash" }).dig("result", "structuredContent", "products").find { _1["name"] == "Ink wash on sale" }

    expect(found).to include("price_cents" => 1000)
  end

  it "quotes a membership at its default recurrence and names that recurrence" do
    recurrence_price_values = [
      { "monthly" => { enabled: true, price: 10 }, "yearly" => { enabled: true, price: 100 } },
      { "monthly" => { enabled: true, price: 15 }, "yearly" => { enabled: true, price: 150 } }
    ]
    create(:membership_product_with_preset_tiered_pricing, :recommendable, name: "Life drawing club", recurrence_price_values:, subscription_duration: "yearly")
    Link.import(refresh: true, force: true)

    found = call_tool({ query: "life drawing club" }).dig("result", "structuredContent", "products").find { _1["name"] == "Life drawing club" }

    expect(found).to include("price_cents" => 10_000, "recurring" => true, "recurrence" => "yearly")
  end

  it "marks a membership pay what you want when one of its tiers is" do
    club = create(:membership_product_with_preset_tiered_pricing, :recommendable, name: "Pastel club")
    club.tiers.first.update_column(:customizable_price, true)
    Link.import(refresh: true, force: true)

    found = call_tool({ query: "pastel club" }).dig("result", "structuredContent", "products").find { _1["name"] == "Pastel club" }

    expect(found).to include("pay_what_you_want" => true)
  end

  it "falls back to the cover image when the product has no thumbnail" do
    product = create(:product, :recommendable, name: "Charcoal portraits")
    create(:asset_preview, link: product).generate_retina_variant!
    Link.import(refresh: true, force: true)

    found = call_tool({ query: "charcoal" }).dig("result", "structuredContent", "products").find { _1["name"] == "Charcoal portraits" }

    expected = Link.find(product.id).thumbnail_or_cover_url
    expect(expected).to be_present
    expect(found["thumbnail_url"]).to eq(expected)
  end

  it "names a seller who has only a username by that username" do
    seller = create(:recommendable_user, name: nil)
    create(:product, :recommendable, user: seller, name: "Gouache landscapes")
    Link.import(refresh: true, force: true)

    found = call_tool({ query: "gouache" }).dig("result", "structuredContent", "products").find { _1["name"] == "Gouache landscapes" }

    expect(found).to include("seller_name" => seller.username)
  end

  it "loads a larger page of results in the same number of queries as a small one" do
    2.times { |i| create(:product, :recommendable, name: "Calligraphy #{i}") }
    Link.import(refresh: true, force: true)
    call_tool({ query: "calligraphy" })
    few = count_queries(matching: /\ASELECT/) { call_tool({ query: "calligraphy" }) }

    4.times { |i| create(:product, :recommendable, name: "Calligraphy #{i + 2}") }
    Link.import(refresh: true, force: true)
    body = nil
    many = count_queries(matching: /\ASELECT/) { body = call_tool({ query: "calligraphy" }) }

    expect(body.dig("result", "structuredContent", "products").size).to eq(6)
    expect(many).to eq(few)
  end

  it "treats a query that is only operators as empty" do
    body = call_tool({ query: "*" })

    expect(body.dig("error", "message")).to include("at least one word")
    expect(body.dig("error", "code")).to eq(-32602)
  end

  it "refuses a blank query instead of returning the whole catalogue" do
    body = call_tool({ query: "   " })

    expect(body.dig("error", "message")).to include("query is required")
    expect(body.dig("error", "code")).to eq(-32602)
  end

  it "refuses a query longer than 200 characters as invalid params" do
    body = call_tool({ query: "a" * 201 })

    expect(body.dig("error", "message")).to include("longer than 200 characters")
    expect(body.dig("error", "code")).to eq(-32602)
  end
end
