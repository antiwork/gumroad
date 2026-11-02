# frozen_string_literal: true

require "spec_helper"

describe "MCP server content links" do
  before do
    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
      create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_#{SecureRandom.hex(8)}")

    @seller = create(:user)
    @app = create(:oauth_application, owner: create(:user))
    @product = create(:product, user: @seller, name: "Notion template", price_cents: 1900)
  end

  def call_tool(name, arguments, scopes: "edit_products", declared: false)
    post_mcp({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name:, arguments: } }, scopes:, declared:)
    response.parsed_body.dig("result")
  end

  def post_mcp(payload, scopes:, declared:, tool_name: nil)
    token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes:)
    headers = {
      "CONTENT_TYPE" => "application/json", "HOST" => DOMAIN, "ACCEPT" => "application/json, text/event-stream",
      "Authorization" => "Bearer #{token.token}"
    }
    if declared
      payload[:_meta] = { Mcp::Server::VERSION_META_KEY => Mcp::Server::MODERN_PROTOCOL_VERSION }
      headers[Mcp::Server::VERSION_HEADER] = Mcp::Server::MODERN_PROTOCOL_VERSION
      headers[Mcp::Server::METHOD_HEADER] = payload[:method].to_s
      headers[Mcp::Server::NAME_HEADER] = tool_name if tool_name
    end
    post "/muse/v1/mcp", params: payload.to_json, headers:
  end

  def text(value)
    { "type" => "paragraph", "content" => [{ "type" => "text", "text" => value }] }
  end

  def button(href, label)
    { "type" => "button", "attrs" => { "href" => href }, "content" => [{ "type" => "text", "text" => label }] }
  end

  describe "add_content_link" do
    it "adds a button buyers see to a product that has no content page yet" do
      result = call_tool("add_content_link", { id: @product.unique_permalink, url: "https://notion.so/template", label: "Open the template" })

      page = @product.reload.alive_rich_contents.sole
      expect(page.description).to eq([button("https://notion.so/template", "Open the template")])
      expect(result.dig("structuredContent", "links")).to eq([
                                                               { "page_id" => page.external_id, "label" => "Open the template", "url" => "https://notion.so/template" }
                                                             ])
      expect(result.dig("structuredContent", "message")).to include("Notion template")
    end

    it "keeps the files buyers already had when it creates their first page" do
      file = create(:product_file, link: @product)

      call_tool("add_content_link", { id: @product.external_id, url: "https://notion.so/template", label: "Duplicate" })

      page = @product.reload.alive_rich_contents.sole
      expect(page.description.first).to include("type" => "fileEmbed", "attrs" => include("id" => file.external_id))
      expect(page.description.last).to eq(button("https://notion.so/template", "Duplicate"))
    end

    it "reports only the button it added, not one already on the page" do
      page = create(:rich_content, entity: @product, description: [button("https://example.com/old", "Old")], position: 0)

      result = call_tool("add_content_link", { id: @product.external_id, url: "https://notion.so/template", label: "Duplicate" })

      expect(result.dig("structuredContent", "links")).to eq([
                                                               { "page_id" => page.external_id, "label" => "Duplicate", "url" => "https://notion.so/template" }
                                                             ])
      expect(page.reload.description.map { _1.dig("attrs", "href") }).to eq(["https://example.com/old", "https://notion.so/template"])
    end

    it "accepts a link with non-ASCII characters, which the editor accepts too" do
      call_tool("add_content_link", { id: @product.external_id, url: "https://notion.so/日本語のテンプレート", label: "Duplicate" })

      expect(@product.reload.alive_rich_contents.sole.description).to eq([button("https://notion.so/日本語のテンプレート", "Duplicate")])
    end

    it "appends the button to the page the buyer reads first, keeping what is on it" do
      existing = text("Thanks for buying. Open your copy below.")
      first = create(:rich_content, entity: @product, description: [existing], position: 0)
      later = create(:rich_content, entity: @product, title: "Bonus", description: [text("Bonus")], position: 1)

      call_tool("add_content_link", { id: @product.external_id, url: "https://notion.so/template", label: "Duplicate" })

      expect(first.reload.description).to eq([existing, button("https://notion.so/template", "Duplicate")])
      expect(later.reload.description).to eq([text("Bonus")])
    end

    it "uses the URL as the text on the button when the creator gives none" do
      call_tool("add_content_link", { id: @product.external_id, url: "https://notion.so/template" })

      expect(@product.reload.alive_rich_contents.sole.description).to eq([button("https://notion.so/template", "https://notion.so/template")])
    end

    it "assumes https for a link with no scheme" do
      call_tool("add_content_link", { id: @product.external_id, url: "notion.so/template", label: "Duplicate" })

      expect(@product.reload.alive_rich_contents.sole.description).to eq([button("https://notion.so/template", "Duplicate")])
    end

    it "keeps a custom scheme, which is how a creator deep-links into their own app" do
      call_tool("add_content_link", { id: @product.external_id, url: "goodsnooze://activate?key=__license_key__", label: "Activate" })

      expect(@product.reload.alive_rich_contents.sole.description).to eq([button("goodsnooze://activate?key=__license_key__", "Activate")])
    end

    it "refuses a scheme a browser would run instead of opening a page" do
      result = call_tool("add_content_link", { id: @product.external_id, url: "javascript:alert(1)", label: "Open" })

      expect(result.dig("isError")).to eq(true)
      expect(result.dig("content", 0, "text")).to include("javascript")
      expect(@product.reload.alive_rich_contents).to be_empty
    end

    it "refuses a local file the reader's browser would open" do
      result = call_tool("add_content_link", { id: @product.external_id, url: "file:///etc/passwd", label: "Open" })

      expect(result.dig("isError")).to eq(true)
      expect(result.dig("content", 0, "text")).to include("file")
      expect(@product.reload.alive_rich_contents).to be_empty
    end

    it "refuses a value that is not a link" do
      result = call_tool("add_content_link", { id: @product.external_id, url: "not a link", label: "Open" })

      expect(result.dig("isError")).to eq(true)
      expect(result.dig("content", 0, "text")).to include("full URL")
      expect(@product.reload.alive_rich_contents).to be_empty
    end

    it "cannot reach another seller's product" do
      @product.update!(user: create(:user))

      result = call_tool("add_content_link", { id: @product.unique_permalink, url: "https://notion.so/template" })

      expect(result.dig("isError")).to eq(true)
      expect(result.dig("content", 0, "text")).to eq("The product was not found.")
    end

    context "when the product gives each version its own pages" do
      before do
        @versioned = create(:product_with_digital_versions, user: @seller)
        @versioned.update!(has_same_rich_content_for_all_variants: false)
      end

      it "adds the button to every version's page" do
        pages = @versioned.alive_variants.map { create(:rich_content, entity: _1, description: [text("This version")], position: 0) }

        call_tool("add_content_link", { id: @versioned.external_id, url: "https://notion.so/template", label: "Duplicate" })

        pages.each do |page|
          expect(page.reload.description).to eq([text("This version"), button("https://notion.so/template", "Duplicate")])
        end
      end

      it "gives a version that has no page one of its own" do
        call_tool("add_content_link", { id: @versioned.external_id, url: "https://notion.so/template", label: "Duplicate" })

        expect(@versioned.alive_variants.map { _1.alive_rich_contents.sole.description }).to all(
          eq([button("https://notion.so/template", "Duplicate")])
        )
        expect(@versioned.alive_rich_contents).to be_empty
      end

      it "adds the button to the product's own page too when buyers without a version read it" do
        product_page = create(:rich_content, entity: @versioned, description: [text("How to use this")], position: 0)
        version_pages = @versioned.alive_variants.map { create(:rich_content, entity: _1, description: [text("This version")], position: 0) }

        call_tool("add_content_link", { id: @versioned.external_id, url: "https://notion.so/template", label: "Duplicate" })

        expect(product_page.reload.description).to eq([text("How to use this"), button("https://notion.so/template", "Duplicate")])
        version_pages.each do |page|
          expect(page.reload.description).to eq([text("This version"), button("https://notion.so/template", "Duplicate")])
        end
      end
    end

    context "when a client runs the handshake a connector runs" do
      before do
        Feature.activate(:mcp_protocol_2026_07_28)
      end

      after do
        Feature.deactivate(:mcp_protocol_2026_07_28)
      end

      it "advertises the tool and adds the button" do
        post_mcp({ jsonrpc: "2.0", id: 1, method: "server/discover" }, scopes: "edit_products", declared: true)
        expect(response.parsed_body.dig("result", "supportedVersions")).to include(Mcp::Server::MODERN_PROTOCOL_VERSION)

        post_mcp({ jsonrpc: "2.0", id: 2, method: "tools/list" }, scopes: "edit_products", declared: true)
        tool = response.parsed_body.dig("result", "tools").find { _1["name"] == "add_content_link" }
        expect(tool["inputSchema"]["required"]).to eq(["id", "url"])

        post_mcp(
          { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "add_content_link", arguments: { id: @product.unique_permalink, url: "https://notion.so/template", label: "Duplicate" } } },
          scopes: "edit_products", declared: true, tool_name: "add_content_link"
        )

        expect(response.parsed_body.dig("result", "structuredContent", "links", 0, "url")).to eq("https://notion.so/template")
      end
    end

    context "when buyers open the product" do
      before do
        host! DOMAIN
      end

      it "serves the button on the download page of a product that has no files" do
        call_tool("add_content_link", { id: @product.unique_permalink, url: "https://notion.so/template", label: "Open the template" })
        purchase = create(:purchase, link: @product, ip_address: "127.0.0.1").tap(&:create_url_redirect!)

        get "/d/#{purchase.url_redirect.token}", headers: { "X-Inertia" => "true" }

        expect(response).to have_http_status(:ok)
        pages = response.parsed_body.dig("props", "content", "rich_content_pages")
        buttons = pages.flat_map { |page| page.dig("description", "content").select { _1["type"] == "button" } }
        expect(buttons.map { _1.dig("attrs", "href") }).to eq(["https://notion.so/template"])
        expect(buttons.sole.dig("content", 0, "text")).to eq("Open the template")
      end

      it "keeps the download rows of a product that has files as well" do
        create(:product_file, link: @product, position: 0)
        call_tool("add_content_link", { id: @product.unique_permalink, url: "https://notion.so/template", label: "Open the template" })
        purchase = create(:purchase, link: @product, ip_address: "127.0.0.1").tap(&:create_url_redirect!)

        get "/d/#{purchase.url_redirect.token}", headers: { "X-Inertia" => "true" }

        expect(response).to have_http_status(:ok)
        page = response.parsed_body.dig("props", "content", "rich_content_pages").sole
        expect(page.dig("description", "content").map { _1["type"] }).to eq(["fileEmbed", "button"])
      end
    end
  end
end
