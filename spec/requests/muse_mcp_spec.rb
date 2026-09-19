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
      "HOST" => DOMAIN,
      "ACCEPT" => "application/json, text/event-stream"
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
      expect { post_mcp({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "create_draft_product", arguments: { name: "Nope", price_cents: 500 } } }) }.not_to change(Link, :count)

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
      expect { post_mcp({ jsonrpc: "2.0", id: 8, method: "tools/call", params: { name: "create_draft_product", arguments: { name: "Nope", price_cents: 500 } } }) }.not_to change(Link, :count)

      expect(response.parsed_body.dig("error", "message")).to include("edit_products")
    end
  end

  context "with a view_sales token" do
    before do
      @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "view_sales")
    end

    it "answers nothing to a notification" do
      post_mcp({ jsonrpc: "2.0", method: "notifications/initialized" })

      expect(response).to have_http_status(:accepted)

      post_mcp({ jsonrpc: "2.0", method: "tools/list" })

      expect(response).to have_http_status(:accepted)
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

  context "protocol and tool regressions" do
    before do
      @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "account")
    end

    def tool_call(name, arguments = {})
      { jsonrpc: "2.0", id: "tool", method: "tools/call", params: { name:, arguments: } }
    end

    it "labels persisted non-USD sales with the currency of their stored USD amount" do
      @product.update!(price_currency_type: Currency::EUR, price_cents: 1000)
      purchase = create(:purchase, seller: @seller, link: @product, price_cents: 1200,
                                   displayed_price_cents: 1000, displayed_price_currency_type: Currency::EUR,
                                   rate_converted_to_usd: "1.2")

      post_mcp(tool_call("list_sales"))

      sale = response.parsed_body.dig("result", "structuredContent", "sales").sole
      expect(purchase.reload.price_cents).to eq(1200)
      expect(purchase.displayed_price_cents).to eq(1000)
      expect(sale).to include("price_cents" => 1200, "currency" => Currency::USD)
    end

    it "rejects GET with a write body without changing the product" do
      body = tool_call("unpublish_product", { id: @product.external_id }).to_json

      expect do
        get "/muse/v1/mcp", headers: { "HOST" => DOMAIN, "Authorization" => "Bearer #{@token.token}",
                                       "ACCEPT" => "text/event-stream", "CONTENT_TYPE" => "application/json" },
                            env: { "rack.input" => StringIO.new(body), "CONTENT_LENGTH" => body.bytesize.to_s }
      end.not_to change { @product.reload.attributes }

      expect(response).to have_http_status(:method_not_allowed)
      expect(response.headers["Allow"]).to eq("POST")
      expect(response.body).to be_empty
    end

    it "rejects GET without a body instead of offering an SSE stream" do
      get "/muse/v1/mcp", headers: { "HOST" => DOMAIN, "Authorization" => "Bearer #{@token.token}", "ACCEPT" => "text/event-stream" }

      expect(response).to have_http_status(:method_not_allowed)
      expect(response.headers["Allow"]).to eq("POST")
    end

    it "responds to each request in a batch using its original ID" do
      post_mcp([{ jsonrpc: "2.0", id: 0, method: "ping" }, { jsonrpc: "2.0", id: "init", method: "initialize" }])

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.first).to eq("jsonrpc" => "2.0", "id" => 0, "result" => {})
      expect(response.parsed_body.last.dig("result", "protocolVersion")).to eq("2025-03-26")
      expect(response.parsed_body.last["id"]).to eq("init")
    end

    it "omits notifications from mixed batch results and isolates invalid elements" do
      post_mcp([
                 { jsonrpc: "2.0", method: "notifications/initialized" },
                 { jsonrpc: "2.0", id: "ok", method: "ping" },
                 tool_call("unknown_tool"),
                 12, [], {},
                 { jsonrpc: "2.0", method: "unknown_notification" }
               ])

      expect(response).to have_http_status(:ok)
      results = response.parsed_body
      expect(results.size).to eq(5)
      expect(results[0]).to include("id" => "ok", "result" => {})
      expect(results[1]).to include("id" => "tool", "error" => include("code" => -32602))
      expect(results.drop(2)).to all(include("id" => nil, "error" => include("code" => -32600)))
    end

    it "executes a valid batch write even when another element is invalid" do
      expect do
        post_mcp([{}, tool_call("create_draft_product", { name: "Batch draft", price_cents: 500 })])
      end.to change(@seller.links, :count).by(1)

      expect(response.parsed_body.first.dig("error", "code")).to eq(-32600)
      expect(@seller.links.order(:id).last).to be_draft
      expect(response.parsed_body.last.dig("result", "structuredContent", "product", "published")).to eq(false)
    end

    it "accepts notification-only batches without a response body" do
      post_mcp([{ jsonrpc: "2.0", method: "notifications/initialized" }, { jsonrpc: "2.0", method: "ping" }])

      expect(response).to have_http_status(:accepted)
      expect(response.body).to be_empty
    end

    it "does not reply to a rejected write notification or create a product" do
      expect do
        post_mcp(tool_call("create_draft_product", { name: "Invalid price", price_cents: -0.9 }).except(:id))
      end.not_to change(Link, :count)

      expect(response).to have_http_status(:accepted)
      expect(response.body).to be_empty
    end

    it "does not reply to a notification whose tool fails a model guard" do
      @seller.update!(confirmed_at: nil)
      @product.update!(draft: true, purchase_disabled_at: Time.current)

      expect do
        post_mcp(tool_call("publish_product", { id: @product.external_id }).except(:id))
      end.not_to change { @product.reload.attributes }

      expect(response).to have_http_status(:accepted)
      expect(response.body).to be_empty
    end

    ["ping", "tools/list", "unknown_notification"].each do |method|
      it "does not reply to a valid #{method} notification" do
        post_mcp({ jsonrpc: "2.0", method: })

        expect(response).to have_http_status(:accepted)
        expect(response.body).to be_empty
      end
    end

    [[], {}, nil, true, 42, "ping"].each do |body|
      it "reports #{body.inspect} as an invalid request rather than a parse error or notification" do
        post_mcp(body)

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to include("id" => nil, "error" => include("code" => -32600))
      end
    end

    it "reports invalid JSON as a parse error" do
      post "/muse/v1/mcp", params: "{", headers: { "HOST" => DOMAIN, "Authorization" => "Bearer #{@token.token}", "CONTENT_TYPE" => "application/json" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to include("id" => nil, "error" => include("code" => -32700))
    end

    [nil, true, {}, [], 1.5].each do |id|
      it "rejects a write with invalid MCP ID #{id.inspect} before creating a product" do
        expect do
          post_mcp(tool_call("create_draft_product", { name: "Invalid envelope", price_cents: 500 }).merge(id:))
        end.not_to change(Link, :count)

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to include("id" => nil, "error" => include("code" => -32600))
      end
    end

    [{ jsonrpc: nil }, { jsonrpc: "1.0" }, { method: nil }, { method: 12 }, { result: {} }, { error: { code: -1, message: "no" } }].each do |invalid|
      it "rejects a write envelope containing #{invalid.inspect} without changing the product" do
        expect do
          post_mcp(tool_call("unpublish_product", { id: @product.external_id }).merge(invalid))
        end.not_to change { @product.reload.attributes }

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to include("id" => "tool", "error" => include("code" => -32600))
      end
    end

    it "rejects a write without a JSON-RPC version" do
      expect do
        post_mcp(tool_call("create_draft_product", { name: "No version", price_cents: 500 }).except(:jsonrpc))
      end.not_to change(Link, :count)

      expect(response.parsed_body).to include("id" => "tool", "error" => include("code" => -32600))
    end

    [{ result: {} }, { error: { code: -32601, message: "Unknown method" } }].each do |reply|
      it "accepts an unsolicited client #{reply.keys.first} without dispatching or replying" do
        expect { post_mcp({ jsonrpc: "2.0", id: "client" }.merge(reply)) }.not_to change(Link, :count)

        expect(response).to have_http_status(:accepted)
        expect(response.body).to be_empty
      end
    end

    it "accepts a batch of well-formed client responses without replying" do
      post_mcp([{ jsonrpc: "2.0", id: 1, result: {} }, { jsonrpc: "2.0", id: 2, error: { code: -32601, message: "Unknown" } }])

      expect(response).to have_http_status(:accepted)
      expect(response.body).to be_empty
    end

    [{ result: {}, error: { code: -1, message: "No" } }, { result: [] }, { error: { code: "bad", message: "No" } }].each do |reply|
      it "rejects malformed client response #{reply.inspect}" do
        post_mcp({ jsonrpc: "2.0", id: "client" }.merge(reply))

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body).to include("id" => "client", "error" => include("code" => -32600))
      end
    end

    [-0.9, 1900.9, -1, "500", true, nil].each do |price_cents|
      it "rejects price #{price_cents.inspect} without creating or publishing a product" do
        expect do
          post_mcp(tool_call("create_draft_product", { name: "Invalid price", price_cents: }))
        end.not_to change(Link, :count)

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body.dig("error", "code")).to eq(-32602)
      end
    end

    it "allows an integer zero price and keeps the new product unpublished" do
      expect do
        post_mcp(tool_call("create_draft_product", { name: "Free draft", price_cents: 0 }))
      end.to change(@seller.links, :count).by(1)

      product = @seller.links.find_by_external_id(response.parsed_body.dig("result", "structuredContent", "product", "id"))
      expect(product.price_cents).to eq(0)
      expect(product).to be_draft
      expect(product).not_to be_published
    end

    [1.5, "2", false, nil, [], 0, 51].each do |limit|
      it "rejects malformed limit #{limit.inspect}" do
        post_mcp(tool_call("list_products", { limit: }))

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body.dig("error", "code")).to eq(-32602)
      end
    end

    it "reports product validation failures as tool errors without persisting a product" do
      expect do
        post_mcp(tool_call("create_draft_product", { name: "a" * 256, price_cents: 500 }))
      end.not_to change(Link, :count)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).not_to have_key("error")
      expect(response.parsed_body.dig("result", "isError")).to eq(true)
      expect(response.parsed_body.dig("result", "content")).to include(include("type" => "text", "text" => include("Name")))
    end

    it "reports a publish guard as a tool error and leaves the draft unchanged" do
      @seller.update!(confirmed_at: nil)
      @product.update!(draft: true, purchase_disabled_at: Time.current)

      expect { post_mcp(tool_call("publish_product", { id: @product.external_id })) }.not_to change { @product.reload.attributes }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).not_to have_key("error")
      expect(response.parsed_body.dig("result", "isError")).to eq(true)
      expect(response.parsed_body.dig("result", "content")).to include(include("type" => "text", "text" => include("confirm your email")))
    end

    %w[publish_product unpublish_product].each do |tool|
      it "refuses #{tool} for another seller without modifying either seller's product" do
        other_product = create(:product, draft: true, purchase_disabled_at: Time.current)

        expect do
          post_mcp(tool_call(tool, { id: other_product.external_id }))
        end.not_to change { [@product.reload.attributes, other_product.reload.attributes] }

        expect(response.parsed_body.dig("result", "isError")).to eq(true)
        expect(response.parsed_body.dig("result", "content")).to include(include("text" => "The product was not found."))
      end

      it "refuses #{tool} without a write scope and leaves the product unchanged" do
        @token.update!(scopes: "view_public")
        @product.update!(draft: true, purchase_disabled_at: Time.current) if tool == "publish_product"

        expect { post_mcp(tool_call(tool, { id: @product.external_id })) }.not_to change { @product.reload.attributes }

        expect(response.parsed_body.dig("error", "message")).to include("edit_products")
      end
    end
  end
end
