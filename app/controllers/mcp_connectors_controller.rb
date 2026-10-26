# frozen_string_literal: true

class McpConnectorsController < ApplicationController
  layout "home"

  CLIENTS = {
    "muse" => {
      label: "Muse",
      pending_review: true,
      setup: "Add a remote MCP server in your client using the URL below. Choose OAuth when the client requests an authentication method.",
      availability: "Submitted for review. The Gumroad connector is not yet available in Muse."
    },
    "claude" => {
      label: "Claude",
      directory_url: "https://claude.ai/directory/gumroad",
      listing_notice: "Listed in Claude’s connector directory. You can also add it as a custom connector.",
      connect_label: "Add Gumroad to Claude",
      setup: "Open Gumroad in Claude’s connector directory and connect it. Or open Settings > Connectors in Claude, choose Add custom connector, and enter the URL below. If you cannot add connectors, ask your organization administrator.",
      availability: "Add Gumroad from Claude’s connector directory. On Team and Enterprise plans, your organization’s settings control which connectors you can add."
    }
  }.freeze

  HELP_ARTICLE_PATH = "355-connect-ai-assistants-to-gumroad"
  SETUP_GUIDE_URL = "https://gumroad.com/help/article/#{HELP_ARTICLE_PATH}"

  before_action :set_client, except: :index
  before_action :set_body_class
  before_action :set_meta_data

  def index
  end

  def show
  end

  private
    def set_client
      @client_key = params[:client].to_s
      @client = CLIENTS[@client_key]
      raise ActionController::RoutingError, "Not Found" if @client.nil?
    end

    def set_body_class
      @hide_layouts = true
    end

    def set_meta_data
      if action_name == "index"
        title = "Gumroad MCP | Sell digital products from your AI assistant"
        description = "Connect your Gumroad store to an AI assistant with Model Context Protocol. List sales, draft products, publish them, and check payouts from your chat."
        page_url = "#{PROTOCOL}://#{DOMAIN}/mcp"
      else
        page_url = "#{PROTOCOL}://#{DOMAIN}/#{@client_key}"
        title = "Gumroad MCP for #{@client[:label]} | Sell digital products"
        description = @client[:pending_review] ? "The Gumroad connector is submitted for review and is not yet available in Muse. Read the MCP endpoint and OAuth details." : "Connect #{@client[:label]} to Gumroad with MCP. Create digital product drafts, publish products, check sales, and track payouts from your AI chat."
      end

      set_meta_tag(title:)
      set_meta_tag(name: "description", content: description)
      set_meta_tag(tag_name: "link", rel: "canonical", href: page_url, head_key: "canonical")
      set_meta_tag(property: "og:title", content: title)
      set_meta_tag(property: "og:description", content: description)
      set_meta_tag(property: "og:type", content: "website")
      set_meta_tag(property: "og:url", content: page_url)
    end
end
