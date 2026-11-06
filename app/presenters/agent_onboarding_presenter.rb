# frozen_string_literal: true

# Builds the props for the Agent dashboard tab, which onboards a creator's own AI assistant
# (Claude, ChatGPT or Muse) onto the store through Gumroad's MCP server.
#
# Must stay cheap for every seller: one indexed query on oauth_access_tokens by the selected
# account's id, nothing from Elasticsearch, no eligibility bar (MCP is open to every seller).
class AgentOnboardingPresenter
  # Order the tab shows the clients in. Keys must exist in Mcp::ConnectorCopy::CLIENTS.
  CLIENT_ORDER = %w[claude chatgpt muse].freeze

  TITLE = "Connect your AI to your Gumroad store"
  DESCRIPTION = "Your own assistant — Claude, ChatGPT or Muse — can read your sales, draft and publish " \
                "products, and check your payouts through Gumroad’s MCP server."

  # Shown on each card under the label. Keyed by client; the connect copy itself comes from
  # Mcp::ConnectorCopy so it matches the marketing pages.
  CAPABILITY = {
    "claude" => "Ask Claude about your sales, draft products, and check payouts.",
    "chatgpt" => "Ask ChatGPT about your sales, draft products, and check payouts.",
    "muse" => "Ask Muse about your sales, draft products, and check payouts.",
  }.freeze

  def initialize(pundit_user:)
    @pundit_user = pundit_user
    @seller = pundit_user.seller
  end

  def index_props
    status = connection_status_by_client

    {
      title: TITLE,
      description: DESCRIPTION,
      clients: CLIENT_ORDER.map { |key| client_props(key, status.fetch(key)) },
      example_prompts: Mcp::ConnectorCopy::EXAMPLE_PROMPTS,
      help_article_url: Mcp::ConnectorCopy::SETUP_GUIDE_URL,
    }
  end

  # { "claude" => { connected:, first_connected_at:, last_used_at: }, ... } for the SELECTED account.
  # MCP consent binds the grant to the account chosen in the switcher, not to the signed-in user
  # (Oauth::AuthorizationsController#current_resource_owner), so a brand's tokens carry the brand's
  # id even when a team member authorized the client. A revoked token keeps its history (first
  # connect, last activity) but does not count as connected.
  # A brand token also stops working the moment the consenting member's sessions are invalidated
  # (MobileAccountToken.valid?, which the API applies to every request), so it must not read as
  # connected either.
  # One indexed query on oauth_access_tokens by resource_owner_id, plus the membership lookup the API
  # would do anyway for a token that carries one; grouped in Ruby by the client path segment, the
  # same match the MCP metrics use.
  def connection_status_by_client
    status = CLIENT_ORDER.index_with { { connected: false, first_connected_at: nil, last_used_at: nil } }

    Doorkeeper::AccessToken
      .where(resource_owner_id: seller.id)
      .where.not(resource: nil)
      .each do |token|
        key = self.class.client_key_for(token.resource)
        next if key.nil?

        entry = status[key]
        entry[:connected] = true if token.revoked_at.nil? && MobileAccountToken.valid?(token)
        entry[:first_connected_at] = [entry[:first_connected_at], token.created_at].compact.min
        # Doorkeeper tokens carry no last-used stamp; the newest token (or its revocation) is the
        # latest activity we can state honestly.
        entry[:last_used_at] = [entry[:last_used_at], token.created_at, token.revoked_at].compact.max
      end

    status
  end

  def self.client_key_for(resource)
    path = resource.to_s
    CLIENT_ORDER.find { |key| path.include?("/#{key}/") }
  end

  private
    attr_reader :pundit_user, :seller

    def client_props(key, status)
      copy = Mcp::ConnectorCopy::CLIENTS.fetch(key)

      {
        key:,
        label: copy[:label],
        capability: CAPABILITY.fetch(key),
        connected: status[:connected],
        first_connected_at: status[:first_connected_at]&.iso8601,
        last_used_at: status[:last_used_at]&.iso8601,
        pending_review: copy[:pending_review] == true,
        directory_url: copy[:directory_url],
        connect_label: copy[:connect_label],
        availability: copy[:availability],
        setup: copy[:setup],
        endpoint_url: Mcp::ConnectorCopy.endpoint_for(key),
      }
    end
end
