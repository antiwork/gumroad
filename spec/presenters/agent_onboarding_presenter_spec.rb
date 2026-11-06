# frozen_string_literal: true

require "spec_helper"

describe AgentOnboardingPresenter do
  let(:seller) { create(:named_seller) }
  let(:pundit_user) { SellerContext.new(user: seller, seller:) }
  let(:presenter) { described_class.new(pundit_user:) }

  def mcp_token(user, client, created_at:, revoked_at: nil, resource_owner: nil, team_membership: nil)
    app = create(:oauth_application, owner: user)
    create("doorkeeper/access_token",
           application: app,
           resource_owner_id: (resource_owner || user).id,
           team_membership_id: team_membership&.id,
           scopes: "view_sales",
           resource: Mcp::DynamicClientOauth.resource_identifier("/#{client}/v1/mcp"),
           created_at:,
           revoked_at:)
  end

  describe "#index_props" do
    it "lists the three clients in order with the shared connector copy" do
      props = presenter.index_props

      expect(props[:title]).to eq(described_class::TITLE)
      expect(props[:clients].map { _1[:key] }).to eq(%w[claude chatgpt muse])
      expect(props[:help_article_url]).to eq("https://gumroad.com/help/article/355-connect-ai-assistants-to-gumroad")
      expect(props[:example_prompts].map { _1[:prompt] }).to eq(["Show my recent sales.", "Draft my next product.", "Check my latest payouts."])

      claude = props[:clients].first
      expect(claude).to include(
        label: "Claude",
        directory_url: "https://claude.ai/directory/gumroad",
        connect_label: "Add Gumroad to Claude",
        setup: "Open Settings > Connectors in Claude, choose Add custom connector, and enter the URL below.",
        endpoint_url: "#{PROTOCOL}://#{DOMAIN}/claude/v1/mcp",
        pending_review: false,
      )

      expect(claude).not_to have_key(:capability)

      chatgpt = props[:clients].second
      expect(chatgpt[:setup]).to be_nil

      muse = props[:clients].last
      expect(muse).to include(label: "Muse", pending_review: true, directory_url: nil, setup: nil)
      expect(muse[:availability]).to eq("Submitted for review. The Gumroad connector is not yet available in Muse.")
    end

    it "leaves the directory step out of every card's setup, since the card's button already links it" do
      presenter.index_props[:clients].filter_map { _1[:setup] }.each do |setup|
        expect(setup).not_to include("directory")
      end
    end

    it "reports every client as not connected for a user with no MCP tokens" do
      props = presenter.index_props

      expect(props[:clients].map { _1[:connected] }).to eq([false, false, false])
      expect(props[:clients].map { _1[:first_connected_at] }).to eq([nil, nil, nil])
    end

    it "reports a client as connected from the user's own MCP tokens, keeping the earliest connect date" do
      mcp_token(seller, "claude", created_at: Time.zone.parse("2026-10-02 10:00"))
      mcp_token(seller, "claude", created_at: Time.zone.parse("2026-09-01 10:00"), revoked_at: Time.zone.parse("2026-09-15 10:00"))

      claude, chatgpt, muse = presenter.index_props[:clients]

      expect(claude[:connected]).to eq(true)
      expect(claude[:first_connected_at]).to eq(Time.zone.parse("2026-09-01 10:00").iso8601)
      expect(claude[:last_used_at]).to eq(Time.zone.parse("2026-10-02 10:00").iso8601)
      expect(chatgpt[:connected]).to eq(false)
      expect(muse[:connected]).to eq(false)
    end

    it "ignores non-MCP tokens and another user's tokens" do
      app = create(:oauth_application, owner: seller)
      create("doorkeeper/access_token", application: app, resource_owner_id: seller.id, scopes: "mobile_api")
      mcp_token(create(:user), "chatgpt", created_at: 1.day.ago)

      expect(presenter.index_props[:clients].map { _1[:connected] }).to eq([false, false, false])
    end

    it "reads status for the selected account, not the signed-in user" do
      admin = create(:user)
      create(:team_membership, user: admin, seller:, role: TeamMembership::ROLE_ADMIN)
      mcp_token(admin, "chatgpt", created_at: 1.day.ago)

      admin_context = SellerContext.new(user: admin, seller:)
      expect(described_class.new(pundit_user: admin_context).index_props[:clients].map { _1[:connected] }).to eq([false, false, false])

      mcp_token(seller, "chatgpt", created_at: 2.days.ago)
      expect(described_class.new(pundit_user: admin_context).index_props[:clients].map { _1[:connected] }).to eq([false, true, false])
    end

    it "reports a client whose tokens are all revoked as not connected, keeping the connect history" do
      mcp_token(seller, "claude", created_at: Time.zone.parse("2026-09-01 10:00"), revoked_at: Time.zone.parse("2026-09-15 10:00"))

      claude = presenter.index_props[:clients].first

      expect(claude[:connected]).to eq(false)
      expect(claude[:first_connected_at]).to eq(Time.zone.parse("2026-09-01 10:00").iso8601)
      expect(claude[:last_used_at]).to eq(Time.zone.parse("2026-09-15 10:00").iso8601)
    end

    it "reports a brand client as not connected once the consenting member's sessions were invalidated, keeping the history" do
      admin = create(:user)
      membership = create(:team_membership, user: admin, seller:, role: TeamMembership::ROLE_ADMIN)
      connected_at = Time.zone.parse("2026-10-02 10:00")
      mcp_token(admin, "claude", created_at: connected_at, resource_owner: seller, team_membership: membership)

      expect(presenter.index_props[:clients].first[:connected]).to eq(true)

      # What a session reset does to the member's tokens: the API stops honouring them
      # (MobileAccountToken.valid?), so the tab must stop saying Connected even though the token
      # itself is not revoked and its history stays.
      admin.update!(last_active_sessions_invalidated_at: connected_at + 1.minute)

      claude = presenter.index_props[:clients].first
      expect(claude[:connected]).to eq(false)
      expect(claude[:first_connected_at]).to eq(connected_at.iso8601)
    end

    it "stops checking a client's tokens once one of them reads as connected" do
      admin = create(:user)
      membership = create(:team_membership, user: admin, seller:, role: TeamMembership::ROLE_ADMIN)
      3.times { |i| mcp_token(admin, "claude", created_at: Time.zone.parse("2026-10-0#{i + 1} 10:00"), resource_owner: seller, team_membership: membership) }

      expect(MobileAccountToken).to receive(:valid?).once.and_call_original

      expect(presenter.index_props[:clients].first[:connected]).to eq(true)
    end

    it "never touches the Elasticsearch sales aggregation" do
      expect(seller).not_to receive(:sales_cents_total)

      presenter.index_props
    end
  end

  describe ".client_key_for" do
    it "matches on the client path segment the MCP metrics use" do
      expect(described_class.client_key_for("https://gumroad.com/claude/v1/mcp")).to eq("claude")
      expect(described_class.client_key_for("https://gumroad.com/chatgpt/v1/mcp")).to eq("chatgpt")
      expect(described_class.client_key_for("https://gumroad.com/muse/v1/mcp")).to eq("muse")
      expect(described_class.client_key_for("https://gumroad.com/other/v1/mcp")).to be_nil
      expect(described_class.client_key_for(nil)).to be_nil
    end
  end
end
