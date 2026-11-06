# frozen_string_literal: true

class McpConnectorsController < ApplicationController
  layout "home"

  # Copy lives in Mcp::ConnectorCopy so the in-app Agent tab shows the same strings. The aliases
  # keep the views and specs that read McpConnectorsController::CLIENTS unchanged.
  CLIENTS = Mcp::ConnectorCopy::CLIENTS
  HELP_ARTICLE_PATH = Mcp::ConnectorCopy::HELP_ARTICLE_PATH
  SETUP_GUIDE_URL = Mcp::ConnectorCopy::SETUP_GUIDE_URL

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
