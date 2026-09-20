# frozen_string_literal: true

class McpConnectorsController < ApplicationController
  layout "home"

  CLIENTS = {
    "muse" => {
      label: "Muse",
      subtitle: "Muse connector",
      title: "Ask Muse.<br class=\"sm:hidden\"> It sells on Gumroad.",
      description: "Connect Muse to a Gumroad account. The agent can list products and sales, draft a product, publish it, and check payouts. People reach a creator just by asking.",
      meta_title: "Gumroad for Muse",
      meta_description: "Connect Muse to Gumroad. Creators can ask Muse to list sales, draft a product, publish it, and check payouts.",
      how_intro: "You bring Gumroad. Muse brings the agent.",
      connect_title: "Paste this into Muse",
      first_card: "OAuth the Gumroad account in Muse. After that, “what did I sell today?” and “draft a $19 guide” run against the live store."
    },
    "claude" => {
      label: "Claude",
      subtitle: "Claude connector",
      title: "Ask Claude.<br class=\"sm:hidden\"> It sells on Gumroad.",
      description: "Add Gumroad as a custom connector in Claude. It can list products and sales, draft a product, publish it, and check payouts for the connected creator.",
      meta_title: "Gumroad for Claude",
      meta_description: "Connect Claude to Gumroad. Creators can ask Claude to list sales, draft a product, publish it, and check payouts.",
      how_intro: "You bring Gumroad. Claude brings the agent.",
      connect_title: "Paste this into Claude",
      first_card: "In Claude, Customize → Connectors → Add custom connector. Paste the MCP URL. Claude opens Gumroad so the creator can authorize."
    },
    "chatgpt" => {
      label: "ChatGPT",
      subtitle: "ChatGPT connector",
      title: "Ask ChatGPT.<br class=\"sm:hidden\"> It sells on Gumroad.",
      description: "Add Gumroad as a ChatGPT connector. It can list products and sales, draft a product, publish it, and check payouts for the connected creator.",
      meta_title: "Gumroad for ChatGPT",
      meta_description: "Connect ChatGPT to Gumroad. Creators can ask ChatGPT to list sales, draft a product, publish it, and check payouts.",
      how_intro: "You bring Gumroad. ChatGPT brings the agent.",
      connect_title: "Paste this into ChatGPT",
      first_card: "In ChatGPT, turn on developer mode, then create a connector with the MCP URL. ChatGPT opens Gumroad so the creator can authorize."
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
      title = @client[:meta_title]
      description = @client[:meta_description]

      set_meta_tag(title:)
      set_meta_tag(name: "description", content: description)
      set_meta_tag(tag_name: "link", rel: "canonical", href: page_url, head_key: "canonical")
      set_meta_tag(property: "og:title", content: title)
      set_meta_tag(property: "og:description", content: description)
      set_meta_tag(property: "og:type", content: "website")
      set_meta_tag(property: "og:url", content: page_url)
    end
end
