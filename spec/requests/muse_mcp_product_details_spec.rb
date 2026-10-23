# frozen_string_literal: true

require "spec_helper"

describe "Muse MCP product details" do
  before do
    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
      create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_#{SecureRandom.hex(8)}")

    @seller = create(:user)
    @app = create(:oauth_application, owner: create(:user))
    @product = create(:product, user: @seller, name: "Field notes", price_cents: 0, description: "<p>Notes from the field.</p>",
                                customizable_price: true, suggested_price_cents: 900)
  end

  def call_tool(name, arguments, scopes:)
    token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes:)
    payload = { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name:, arguments: } }
    post "/muse/v1/mcp", params: payload.to_json, headers: {
      "CONTENT_TYPE" => "application/json", "HOST" => DOMAIN, "ACCEPT" => "application/json, text/event-stream",
      "Authorization" => "Bearer #{token.token}"
    }
    response.parsed_body.dig("result", "structuredContent")
  end

  it "lists a pay-what-you-want product with its minimum and suggested price" do
    fixed = create(:product, user: @seller, name: "Fixed price", price_cents: 1500)

    products = call_tool("list_products", {}, scopes: "edit_products")["products"].index_by { _1["id"] }

    expect(products[@product.external_id]).to include("price_cents" => 0, "pay_what_you_want" => true, "suggested_price_cents" => 900)
    expect(products[fixed.external_id]).to include("price_cents" => 1500, "pay_what_you_want" => false, "suggested_price_cents" => nil)
  end

  it "returns the description, and the sales count and revenue with a sales scope" do
    create(:purchase, link: @product, seller: @seller, price_cents: 900)
    create(:purchase, link: @product, seller: @seller, price_cents: 1200)
    index_model_records(Purchase)

    product = call_tool("get_product", { id: @product.unique_permalink }, scopes: "edit_products view_sales")["product"]

    expect(product).to include("description" => "<p>Notes from the field.</p>", "pay_what_you_want" => true,
                               "sales_count" => 2, "sales_usd_cents" => 2100)
  end

  it "leaves out sales figures without a sales scope" do
    product = call_tool("get_product", { id: @product.unique_permalink }, scopes: "edit_products")["product"]

    expect(product).to include("description" => "<p>Notes from the field.</p>")
    expect(product.keys).not_to include("sales_count", "sales_usd_cents")
  end
end
