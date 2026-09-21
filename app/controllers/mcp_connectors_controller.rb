# frozen_string_literal: true

class McpConnectorsController < ApplicationController
  layout "home"

  CLIENTS = {
    "muse" => {
      label: "Muse",
      setup: "Add a remote MCP server in your client using the URL below. Choose OAuth when the client requests an authentication method.",
      availability: "Requires a Muse client with support for remote MCP servers and OAuth."
    },
    "claude" => {
      label: "Claude",
      setup: "Open the Connectors settings in Claude. Add a custom connector with the URL below.",
      availability: "Custom connector access depends on your Claude plan and workspace settings."
    }
  }.freeze

  before_action :set_client
  before_action :set_body_class
  before_action :set_meta_data

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
      page_url = "#{PROTOCOL}://#{DOMAIN}/#{@client_key}"
      title = "Gumroad MCP for #{@client[:label]} | Sell digital products"
      description = "Connect #{@client[:label]} to Gumroad with MCP. Create digital product drafts, publish products, check sales, and track payouts from your AI chat."

      set_meta_tag(title:)
      set_meta_tag(name: "description", content: description)
      set_meta_tag(tag_name: "link", rel: "canonical", href: page_url, head_key: "canonical")
      set_meta_tag(property: "og:title", content: title)
      set_meta_tag(property: "og:description", content: description)
      set_meta_tag(property: "og:type", content: "website")
      set_meta_tag(property: "og:url", content: page_url)
    end
end
