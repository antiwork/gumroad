# frozen_string_literal: true

require "spec_helper"

describe "MCP server product search" do
  before do
    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
      create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_#{SecureRandom.hex(8)}")

    @seller_tokens = create(:user)
    @seller = create(:recommendable_user, name: "Ada")
    @app = create(:oauth_application, owner: create(:user))
    @product = create(:product, :recommendable, user: @seller, name: "Learn to draw faces", price_cents: 1500)
    create(:product, :recommendable, user: create(:recommendable_user, name: "Grace"), name: "Watercolour for beginners", price_cents: 900)
    Link.import(refresh: true, force: true)
  end

  def call_tool(arguments, scopes: "view_public")
    token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller_tokens.id, scopes:)
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

  it "drops a product that stopped being visible after the index was written" do
    unpublished = create(:product, :recommendable, user: @seller, name: "Drawing drills", price_cents: 500)
    deleted = create(:product, :recommendable, user: @seller, name: "Drawing deleted", price_cents: 500)
    banned = create(:product, :recommendable, user: @seller, name: "Drawing banned", price_cents: 500)
    Link.import(refresh: true, force: true)

    # The index still holds all three; only the rows change, which is the lag the row check covers.
    unpublished.update_column(:purchase_disabled_at, Time.current)
    deleted.update_column(:deleted_at, Time.current)
    banned.update_column(:banned_at, Time.current)

    names = call_tool({ query: "draw" }).dig("result", "structuredContent", "products").map { _1["name"] }

    expect(names).to include("Learn to draw faces")
    expect(names).not_to include("Drawing drills", "Drawing deleted", "Drawing banned")
  end

  it "treats a query that is only operators as empty" do
    body = call_tool({ query: "*" })

    expect(body.dig("error", "message")).to include("at least one word")
  end

  it "refuses a blank query instead of returning the whole catalogue" do
    body = call_tool({ query: "   " })

    expect(body.dig("error", "message")).to include("query is required")
  end
end
