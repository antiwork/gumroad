# frozen_string_literal: true

require "spec_helper"

describe McpConnectorsController do
  render_views

  it "documents Claude custom setup without claiming a directory listing" do
    get :show, params: { client: "claude" }

    expect(response).to be_successful
    expect(response.body).to include("Available as a custom connector", "not yet listed in Claude’s connector directory", "Set up a custom connector")
    expect(response.body).to include("/claude/v1/mcp", "organization administrator", "Review the requested permissions before you authorize access")
    expect(response.body).not_to include("Submitted for review")
  end

  it "shows review status and technical details without Muse setup instructions" do
    get :show, params: { client: "muse" }

    expect(response.body).to include("not yet available in Muse", "View technical details", "/muse/v1/mcp", "/.well-known/oauth-authorization-server")
    expect(Nokogiri::HTML(response.body).at_css('#connect a[href="/.well-known/mcp.json"]')&.text).to eq("MCP discovery")
    expect(response.body).not_to include("Connect your store", "1. Add the connector", "Select the connector in your chat")
  end

  it "documents how to revoke connector access" do
    get :show, params: { client: "claude" }

    expect(response.body).to include("Disconnect the connector in your MCP client")
    expect(Nokogiri::HTML(response.body).at_css('a[href="/settings/authorized_applications"]')).to be_present
  end

  before { allow(GithubStarsController).to receive(:cached_count).and_return(1234) }

  {
    "muse" => "Gumroad MCP for Muse | Sell digital products",
    "claude" => "Gumroad MCP for Claude | Sell digital products"
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
end
