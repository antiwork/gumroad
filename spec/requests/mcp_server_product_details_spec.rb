# frozen_string_literal: true

require "spec_helper"

describe "MCP server product details" do
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

  it "lists a membership's pricing per tier and billing period" do
    membership = create(:membership_product, user: @seller, name: "Club")
    tier = membership.tiers.sole
    tier.update!(name: "Supporter", customizable_price: true)
    tier.save_recurring_prices!("monthly" => { enabled: true, price: "3", suggested_price: "5" }, "yearly" => { enabled: true, price: "30" })

    product = call_tool("get_product", { id: membership.unique_permalink }, scopes: "edit_products")["product"]

    expect(product).to include("pay_what_you_want" => true, "suggested_price_cents" => nil)
    expect(product["tiers"]).to eq([{
                                     "id" => tier.external_id, "name" => "Supporter", "pay_what_you_want" => true,
                                     "prices" => { "monthly" => { "price_cents" => 300, "suggested_price_cents" => 500 },
                                                   "yearly" => { "price_cents" => 3000, "suggested_price_cents" => nil } }
                                   }])
  end

  it "lists memberships without a query per tier or billing period" do
    3.times do |i|
      create(:membership_product, user: @seller, name: "Club #{i}").tiers.sole
        .save_recurring_prices!("monthly" => { enabled: true, price: "3" }, "yearly" => { enabled: true, price: "30" })
    end
    call_tool("list_products", { limit: 1 }, scopes: "edit_products")
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] if payload[:sql].match?(/\ASELECT/i) && payload[:name] != "SCHEMA" }

    products = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      call_tool("list_products", {}, scopes: "edit_products")["products"]
    end

    expect(products.count { _1["tiers"] }).to eq(3)
    expect(queries.count { _1.include?("`prices`") }).to be <= 2
  end

  describe "a membership with a fixed-price tier and a pay-what-you-want tier" do
    before do
      @membership = create(:membership_product, user: @seller, name: "Field club")
      @reader = @membership.tiers.sole
      @reader.update!(name: "Reader")
      @supporter = create(:variant, variant_category: @reader.variant_category, name: "Supporter", customizable_price: true)
      @reader.save_recurring_prices!("monthly" => { enabled: true, price: "5" }, "yearly" => { enabled: true, price: "50" })
      @supporter.save_recurring_prices!("monthly" => { enabled: true, price: "10", suggested_price: "15" },
                                        "yearly" => { enabled: true, price: "100", suggested_price: "150" })
    end

    it "leaves out the product-level $0 price, and leaves regular products as they were" do
      products = call_tool("list_products", {}, scopes: "edit_products")["products"].index_by { _1["id"] }

      expect(products[@membership.external_id]).to include("price_cents" => nil, "pay_what_you_want" => true, "suggested_price_cents" => nil)
      expected_tiers = [
        { "id" => @reader.external_id, "name" => "Reader", "pay_what_you_want" => false,
          "prices" => { "monthly" => { "price_cents" => 500, "suggested_price_cents" => nil },
                        "yearly" => { "price_cents" => 5000, "suggested_price_cents" => nil } } },
        { "id" => @supporter.external_id, "name" => "Supporter", "pay_what_you_want" => true,
          "prices" => { "monthly" => { "price_cents" => 1000, "suggested_price_cents" => 1500 },
                        "yearly" => { "price_cents" => 10000, "suggested_price_cents" => 15000 } } },
      ]
      expect(products[@membership.external_id]["tiers"]).to eq(expected_tiers)
      expect(products[@product.external_id]).to include("price_cents" => 0, "pay_what_you_want" => true, "suggested_price_cents" => 900)
      expect(products[@product.external_id]).not_to have_key("tiers")
    end

    it "leaves out a suggested price kept from when a tier was pay what you want" do
      @supporter.update!(customizable_price: false)

      product = call_tool("get_product", { id: @membership.external_id }, scopes: "edit_products")["product"]

      expect(product["tiers"].last["prices"].values.pluck("suggested_price_cents")).to eq([nil, nil])
      expect(product).to include("price_cents" => nil, "pay_what_you_want" => false, "suggested_price_cents" => nil)
    end

    it "does not call the membership pay what you want when only a tier closed to new buyers is" do
      Feature.activate_user(:close_membership_tier_to_new_buyers, @seller)
      @supporter.update!(closed_to_new_purchases: true)

      product = call_tool("get_product", { id: @membership.external_id }, scopes: "edit_products")["product"]

      expect(product).to include("pay_what_you_want" => false)
      expect(product["tiers"].pluck("pay_what_you_want")).to eq([false, true])
    end
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
