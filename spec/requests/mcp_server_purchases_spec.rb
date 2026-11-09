# frozen_string_literal: true

require "spec_helper"

describe "MCP server purchases" do
  before do
    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
      create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_#{SecureRandom.hex(8)}")

    @buyer = create(:user)
    @seller = create(:user, name: "Ada")
    @app = create(:oauth_application, owner: create(:user))
    @bought = create(:product, user: @seller, name: "Field notes", price_cents: 1900)
    @also_bought = create(:product, user: @seller, name: "Second book", price_cents: 900)
    @someone_elses = create(:product, user: create(:user, name: "Grace"), name: "Not mine", price_cents: 500)
  end

  def call_tool(name, arguments = {}, scopes: "view_library")
    token = create("doorkeeper/access_token", application: @app, resource_owner_id: @buyer.id, scopes:)
    payload = { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name:, arguments: } }
    post "/muse/v1/mcp", params: payload.to_json, headers: {
      "CONTENT_TYPE" => "application/json", "HOST" => DOMAIN, "ACCEPT" => "application/json",
      "Authorization" => "Bearer #{token.token}"
    }
    response.parsed_body.dig("result")
  end

  it "lists the products the connected creator bought, newest first" do
    create(:purchase, purchaser: @buyer, link: @bought, price_cents: 1900, created_at: 2.days.ago)
    create(:purchase, purchaser: @buyer, link: @also_bought, price_cents: 900, created_at: 1.day.ago)

    result = call_tool("list_purchases")

    purchases = result.dig("structuredContent", "purchases")
    expect(purchases.map { _1["product_name"] }).to eq(["Second book", "Field notes"])
    expect(purchases.first).to include(
      "price_cents" => 900,
      "currency" => "usd",
      "seller_name" => "Ada",
      "refunded" => false,
      "url" => "#{PROTOCOL}://#{DOMAIN}/library"
    )
    expect(purchases.first["purchased_at"]).to be_present
    expect(purchases.first["id"]).to be_present
  end

  it "leaves out purchases that belong to someone else" do
    create(:purchase, purchaser: @buyer, link: @bought)
    create(:purchase, purchaser: @seller, link: @someone_elses)

    purchases = call_tool("list_purchases").dig("structuredContent", "purchases")

    expect(purchases.map { _1["product_name"] }).to eq(["Field notes"])
  end

  it "keeps free-trial and gifted purchases, and skips one whose product row is gone" do
    create(:purchase, purchaser: @buyer, link: @bought, purchase_state: "not_charged", created_at: 3.days.ago)
    create(:purchase, purchaser: @buyer, link: @also_bought, purchase_state: "gift_receiver_purchase_successful", created_at: 2.days.ago)
    orphan = create(:purchase, purchaser: @buyer, link: @someone_elses, created_at: 1.day.ago)
    orphan.update_column(:link_id, 0)

    purchases = call_tool("list_purchases").dig("structuredContent", "purchases")

    expect(purchases.map { _1["product_name"] }).to eq(["Second book", "Field notes"])
  end

  it "reports the amount in the currency the buyer paid" do
    purchase = create(:purchase, purchaser: @buyer, link: @bought)
    purchase.update_columns(displayed_price_cents: 1500, displayed_price_currency_type: "eur")

    entry = call_tool("list_purchases").dig("structuredContent", "purchases").first

    expect(entry).to include("price_cents" => 1500, "currency" => "eur")
  end

  it "asks for the library scope it needs" do
    other = create("doorkeeper/access_token", application: @app, resource_owner_id: @buyer.id, scopes: "view_sales")
    post "/muse/v1/mcp", params: { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "list_purchases", arguments: {} } }.to_json,
                         headers: { "CONTENT_TYPE" => "application/json", "HOST" => DOMAIN, "Authorization" => "Bearer #{other.token}" }

    expect(response.parsed_body.dig("error", "message")).to include("view_library")
  end

  it "refuses the legacy account scope that reaches every older tool" do
    create(:purchase, purchaser: @buyer, link: @bought)
    legacy = create("doorkeeper/access_token", application: @app, resource_owner_id: @buyer.id, scopes: "account")
    post "/muse/v1/mcp", params: { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "list_purchases", arguments: {} } }.to_json,
                         headers: { "CONTENT_TYPE" => "application/json", "HOST" => DOMAIN, "Authorization" => "Bearer #{legacy.token}" }

    expect(response.parsed_body.dig("error", "message")).to include("view_library")
    expect(response.parsed_body.dig("result", "structuredContent", "purchases")).to be_nil
  end
end
