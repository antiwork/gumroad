# frozen_string_literal: true

require "spec_helper"

describe "Muse MCP" do
  before do
    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
      create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_#{SecureRandom.hex(8)}")

    @seller = create(:user)
    @app = create(:oauth_application, owner: create(:user))
    @product = create(:product, user: @seller, name: "Field notes", price_cents: 1900)
  end

  def post_mcp(payload, token: @token)
    headers = {
      "CONTENT_TYPE" => "application/json",
      "HOST" => DOMAIN
    }
    headers["Authorization"] = "Bearer #{token.token}" if token
    post "/muse/v1/mcp", params: payload.to_json, headers:
  end

  it "exposes a public status endpoint" do
    get "/muse/v1/status", headers: { "HOST" => DOMAIN }

    expect(response).to be_successful
    expect(response.parsed_body).to eq("status" => "success")
  end

  it "advertises the MCP endpoint and OAuth" do
    get "/.well-known/mcp.json", headers: { "HOST" => DOMAIN }

    expect(response).to be_successful
    body = response.parsed_body
    expect(body["name"]).to eq("Gumroad")
    expect(body["mcp"]).to eq("#{PROTOCOL}://#{DOMAIN}/muse/v1/mcp")
    expect(body["oauth"]["authorization_endpoint"]).to eq("#{PROTOCOL}://#{DOMAIN}/muse/v1/oauth2/authorize")
    expect(body["oauth"]["scopes"]).to include("view_sales", "edit_products")
  end

  it "returns RFC 8414 metadata" do
    get "/.well-known/oauth-authorization-server", headers: { "HOST" => DOMAIN }

    expect(response).to be_successful
    body = response.parsed_body
    expect(body["issuer"]).to eq("#{PROTOCOL}://#{DOMAIN}")
    expect(body["authorization_endpoint"]).to end_with("/muse/v1/oauth2/authorize")
    expect(body["token_endpoint"]).to end_with("/muse/v1/oauth2/token")
    expect(body["code_challenge_methods_supported"]).to include("S256")
  end

  it "returns 401 without a token" do
    post_mcp({ jsonrpc: "2.0", id: 1, method: "ping" }, token: nil)

    expect(response).to have_http_status(:unauthorized)
  end

  context "with a view_sales token" do
    before do
      @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "view_sales")
    end

    it "lists tools" do
      post_mcp({ jsonrpc: "2.0", id: 1, method: "tools/list" })

      expect(response).to be_successful
      names = response.parsed_body.dig("result", "tools").map { |tool| tool["name"] }
      expect(names).to include("get_account", "list_products", "list_sales", "create_draft_product", "publish_product")
    end

    it "lists sales" do
      purchase = create(:purchase, seller: @seller, link: @product, email: "buyer@example.com", price_cents: 1900)

      post_mcp({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "list_sales", arguments: {} } })

      expect(response).to be_successful
      sales = response.parsed_body.dig("result", "structuredContent", "sales")
      expect(sales.map { |sale| sale["id"] }).to include(purchase.external_id)
      listed = sales.find { |sale| sale["id"] == purchase.external_id }
      expect(listed["email"]).to eq("buyer@example.com")
      expect(listed["refunded"]).to eq(false)
    end

    it "refuses a write tool" do
      post_mcp({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "create_draft_product", arguments: { name: "Nope", price_cents: 500 } } })

      expect(response.parsed_body.dig("error", "message")).to include("edit_products")
    end
  end

  context "with an edit_products token" do
    before do
      @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "edit_products")
    end

    it "creates a draft and does not publish it" do
      post_mcp({ jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "create_draft_product", arguments: { name: "Muse draft", price_cents: 1900, description: "A note." } } })

      expect(response).to be_successful
      payload = response.parsed_body.dig("result", "structuredContent", "product")
      expect(payload["name"]).to eq("Muse draft")
      expect(payload["published"]).to eq(false)
      product = @seller.links.find_by_external_id(payload["id"])
      expect(product).to be_draft
      expect(product.purchase_disabled_at).to be_present
    end

    it "publishes an existing product the seller owns" do
      @product.update!(draft: true, purchase_disabled_at: Time.current)

      post_mcp({ jsonrpc: "2.0", id: 5, method: "tools/call", params: { name: "publish_product", arguments: { id: @product.external_id } } })

      expect(response).to be_successful
      expect(response.parsed_body.dig("result", "structuredContent", "product", "published")).to eq(true)
      expect(@product.reload).to be_published
    end
  end

  context "with a default-scope (view_public) token" do
    before do
      @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "view_public")
    end

    it "lists tools and reads products" do
      post_mcp({ jsonrpc: "2.0", id: 6, method: "tools/list" })
      expect(response).to be_successful

      post_mcp({ jsonrpc: "2.0", id: 7, method: "tools/call", params: { name: "list_products", arguments: {} } })
      expect(response).to be_successful
      names = response.parsed_body.dig("result", "structuredContent", "products").map { |product| product["name"] }
      expect(names).to include("Field notes")
    end

    it "refuses a write tool" do
      post_mcp({ jsonrpc: "2.0", id: 8, method: "tools/call", params: { name: "create_draft_product", arguments: { name: "Nope", price_cents: 500 } } })

      expect(response.parsed_body.dig("error", "message")).to include("edit_products")
    end
  end

  context "with a view_sales token" do
    before do
      @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "view_sales")
    end

    it "answers nothing to a notification" do
      post_mcp({ jsonrpc: "2.0", method: "notifications/initialized" })

      expect(response).to have_http_status(:no_content)

      post_mcp({ jsonrpc: "2.0", method: "tools/list" })

      expect(response).to have_http_status(:no_content)
    end

    it "reports invalid params rather than crashing" do
      post_mcp({ jsonrpc: "2.0", id: 9, method: "tools/call", params: [] })

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body.dig("error", "code")).to eq(-32602)

      post_mcp({ jsonrpc: "2.0", id: 10, method: "tools/call", params: { name: "list_sales", arguments: [] } })

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body.dig("error", "code")).to eq(-32602)

      post_mcp({ jsonrpc: "2.0", id: 11, method: "tools/call", params: { name: "list_sales", arguments: { limit: true } } })

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body.dig("error", "code")).to eq(-32602)
    end
  end
end
