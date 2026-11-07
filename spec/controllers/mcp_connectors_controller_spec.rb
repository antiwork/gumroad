# frozen_string_literal: true

require "spec_helper"

describe McpConnectorsController do
  render_views

  it "points Claude setup at the connector directory and keeps the custom connector path" do
    get :show, params: { client: "claude" }

    expect(response).to be_successful
    expect(response.body).to include("Listed in Claude’s connector directory", "Add Gumroad to Claude", "Add custom connector")
    expect(Nokogiri::HTML(response.body).css('a[href="https://claude.ai/directory/gumroad"]').size).to be >= 2
    expect(response.body).not_to include("not yet listed")
    expect(response.body).to include("/claude/v1/mcp", "organization administrator", "Review the requested permissions before you authorize access")
    expect(response.body).not_to include("Submitted for review")
  end

  it "points ChatGPT setup at the plugin directory" do
    get :show, params: { client: "chatgpt" }

    expect(response).to be_successful
    expect(response.body).to include("Listed in ChatGPT’s plugin directory", "Add Gumroad to ChatGPT", "Add Gumroad from ChatGPT’s plugin directory")
    expect(Nokogiri::HTML(response.body).css('a[href="https://chatgpt.com/plugins/plugin_asdk_app_6adf8e8e7eac8191a9af1b87fdeedb45"]').size).to be >= 2
    expect(response.body).to include("/chatgpt/v1/mcp", "Review the requested permissions before you authorize access")
    expect(response.body).not_to include("Submitted for review")
  end

  it "shows review status and technical details without Muse setup instructions" do
    get :show, params: { client: "muse" }

    expect(response.body).to include("not yet available in Muse", "View technical details", "/muse/v1/mcp", "/.well-known/oauth-authorization-server")
    expect(Nokogiri::HTML(response.body).at_css('#connect a[href="/.well-known/mcp.json"]')&.text).to eq("MCP discovery")
    expect(response.body).not_to include("Connect your store", "1. Add the connector", "Select the connector in your chat")
  end

  it "offers Cursor a custom remote server address" do
    get :show, params: { client: "cursor" }

    expect(response).to be_successful
    expect(response.body).to include("Gumroad MCP", "Cursor", "/cursor/v1/mcp", "Add Gumroad to Cursor")
    expect(response.body).to include("no published Gumroad listing in Cursor")
    expect(response.body).not_to include("not yet available in", "Cursor’s connector directory")
  end

  it "offers Antigravity a custom remote server address" do
    get :show, params: { client: "antigravity" }

    expect(response).to be_successful
    expect(response.body).to include("Google Antigravity", "/antigravity/v1/mcp", "Add Gumroad to Antigravity")
    expect(response.body).not_to include("not yet available in", "Antigravity’s connector directory")
  end

  it "documents how to revoke connector access" do
    get :show, params: { client: "claude" }

    expect(response.body).to include("Revoke the connection any time in", "Settings &gt; Applications", "does not revoke its access token")
    expect(Nokogiri::HTML(response.body).at_css('a[href="/settings/authorized_applications"]')).to be_present
  end

  it "links connector and setup pages to each other" do
    get :show, params: { client: "claude" }
    expect(Nokogiri::HTML(response.body).at_css("a[href=\"#{McpConnectorsController::SETUP_GUIDE_URL}\"]")).to be_present
    expect(Nokogiri::HTML(response.body).at_css('a[href="/mcp"]')).to be_present
    expect(Nokogiri::HTML(response.body).at_css('a[href="/muse"]')).to be_present
  end

  describe "index" do
    it "lists every connector with its real availability" do
      get :index

      expect(response).to be_successful
      expect(response.body).to include("Gumroad MCP for Claude", "Available now in Claude’s connector directory", "Listed in Claude’s connector directory")
      expect(response.body).not_to include("not yet listed")
      expect(response.body).to include("Gumroad MCP for Muse", "not yet available in Muse")
      expect(response.body).to include("Gumroad MCP for Cursor", "Available now as a custom connector.")
      expect(response.body).to include("Gumroad MCP for Google Antigravity")
      expect(response.body).to include("Gumroad MCP for ChatGPT", "Available now in ChatGPT’s plugin directory", "Listed in ChatGPT’s plugin directory")
      expect(response.body).not_to include("Not available yet")
      expect(response.body).not_to include("Connect your store")
    end

    it "links setup, connector, and revoke paths" do
      get :index

      html = Nokogiri::HTML(response.body)
      expect(html.css('a[href="/claude"]')).to be_present
      expect(html.css('a[href="/muse"]')).to be_present
      expect(html.at_css("a[href=\"#{McpConnectorsController::SETUP_GUIDE_URL}\"]")).to be_present
      expect(html.css('a[href="/settings/authorized_applications"]')).to be_present
      expect(html.at_css('#connect a[href="/claude"]')&.text).to eq("Gumroad MCP for Claude connector page")
    end

    it "does not claim a Muse connection path and lists ChatGPT in its plugin directory" do
      get :index

      expect(Nokogiri::HTML(response.body).css('article a[href="/muse"]').map(&:text)).to eq(["Read the technical details"])
      expect(Nokogiri::HTML(response.body).css('article a[href="/chatgpt"]').map(&:text)).to eq(["Set up Gumroad MCP"])
      expect(response.body).not_to include("developer mode")
    end
  end

  before { allow(GithubStarsController).to receive(:cached_count).and_return(1234) }

  {
    "muse" => "Gumroad MCP for Muse | Sell digital products",
    "claude" => "Gumroad MCP for Claude | Sell digital products",
    "chatgpt" => "Gumroad MCP for ChatGPT | Sell digital products"
  }.each do |client, title|
    it "sets title, description, and canonical for #{client}" do
      get :show, params: { client: }

      expect(response).to be_successful
      expect(assigns(:hide_layouts)).to be(true)

      description = client == "muse" ? "The Gumroad connector is submitted for review and is not yet available in Muse. Read the MCP endpoint and OAuth details." : "Connect #{McpConnectorsController::CLIENTS[client][:label]} to Gumroad with MCP. Create digital product drafts, publish products, check sales, and track payouts from your AI chat."
      page_url = "#{PROTOCOL}://#{DOMAIN}/#{client}"
      tags = controller.send(:meta_tags)

      expect(controller.send(:page_title)).to eq(title)
      expect(tags["title"][:inner_content]).to eq(title)
      expect(tags["meta-name-description"][:content]).to eq(description)
      expect(tags["canonical"][:href]).to eq(page_url)
      expect(tags["meta-property-og-title"][:content]).to eq(title)
      expect(tags["meta-property-og-description"][:content]).to eq(description)
      expect(tags["meta-property-og-url"][:content]).to eq(page_url)
    end
  end

  it "sets title, description, and canonical for the index" do
    get :index

    title = "Gumroad MCP | Sell digital products from your AI assistant"
    description = "Connect your Gumroad store to an AI assistant with Model Context Protocol. List sales, draft products, publish them, and check payouts from your chat."
    page_url = "#{PROTOCOL}://#{DOMAIN}/mcp"
    tags = controller.send(:meta_tags)

    expect(assigns(:hide_layouts)).to be(true)
    expect(controller.send(:page_title)).to eq(title)
    expect(tags["title"][:inner_content]).to eq(title)
    expect(tags["meta-name-description"][:content]).to eq(description)
    expect(tags["canonical"][:href]).to eq(page_url)
    expect(tags["meta-property-og-title"][:content]).to eq(title)
    expect(tags["meta-property-og-description"][:content]).to eq(description)
    expect(tags["meta-property-og-url"][:content]).to eq(page_url)
  end
end
