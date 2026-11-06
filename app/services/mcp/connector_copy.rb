# frozen_string_literal: true

module Mcp
  # The one place the per-client MCP connector copy lives. Both the public marketing pages
  # (McpConnectorsController, /mcp and /<client>) and the in-app Agent tab
  # (AgentOnboardingPresenter) read from here, so the two surfaces cannot drift.
  #
  # Keep CLIENTS in this order: it is the order the marketing pages render the clients in.
  #
  # `setup` is the marketing pages' full instructions. `manual_setup` is the Agent tab's Setup
  # section, which sits under the directory button and the `availability` note, so it leaves out
  # the directory step and the plan note those already give. A client without one gets no Setup
  # section: ChatGPT has no manual path in this copy, and Muse is under review, so creators get no
  # Muse setup path until it is listed.
  module ConnectorCopy
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
        manual_setup: "Open Settings > Connectors in Claude, choose Add custom connector, and enter the URL below.",
        availability: "Add Gumroad from Claude’s connector directory. On Team and Enterprise plans, your organization’s settings control which connectors you can add."
      },
      "chatgpt" => {
        label: "ChatGPT",
        directory_url: "https://chatgpt.com/plugins/plugin_asdk_app_6adf8e8e7eac8191a9af1b87fdeedb45",
        directory_name: "plugin directory",
        listing_notice: "Listed in ChatGPT’s plugin directory.",
        connect_label: "Add Gumroad to ChatGPT",
        setup: "Open Gumroad in ChatGPT’s plugin directory and connect it. If you cannot add plugins, ask your workspace administrator.",
        availability: "Add Gumroad from ChatGPT’s plugin directory."
      }
    }.freeze

    HELP_ARTICLE_PATH = "355-connect-ai-assistants-to-gumroad"
    SETUP_GUIDE_URL = "https://gumroad.com/help/article/#{HELP_ARTICLE_PATH}"

    # The example prompts shown on the marketing page and the Agent tab.
    EXAMPLE_PROMPTS = [
      { prompt: "Show my recent sales.", description: "See which products people bought and what they paid." },
      { prompt: "Draft my next product.", description: "Ask for a product name, price, and description. Add the product files in Gumroad before publishing." },
      { prompt: "Check my latest payouts.", description: "Check recent payout amounts and their status." },
    ].freeze

    # The remote MCP server URL a creator pastes into a client's custom-connector form. Not named
    # `*_url`: CONTRIBUTING.md reserves that suffix for generated route helpers.
    def self.endpoint_for(client_key)
      "#{PROTOCOL}://#{DOMAIN}/#{client_key}/v1/mcp"
    end
  end
end
