# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"
require "shared_examples/authorize_called"

describe AgentController, type: :controller, inertia: true do
  render_views

  let(:seller) { create(:named_seller) }

  before do
    sign_in seller
  end

  it_behaves_like "authorize called for action", :get, :index do
    let(:record) { seller }
    let(:policy_klass) { UserPolicy }
    let(:policy_method) { :view_store_agent? }
  end

  describe "GET index" do
    it "renders the MCP onboarding page for the owner with every client not connected" do
      get :index

      expect(response).to be_successful
      expect(inertia).to render_component("Agent/Index")
      expect(inertia.props[:title]).to eq("Connect your AI to your Gumroad store")
      expect(inertia.props[:clients].map { _1[:key] }).to eq(%w[claude chatgpt muse])
      expect(inertia.props[:clients].map { _1[:connected] }).to eq([false, false, false])
      expect(inertia.props[:help_article_url]).to eq(Mcp::ConnectorCopy::SETUP_GUIDE_URL)
    end

    it "marks a client connected when the selected account holds an MCP token for it" do
      app = create(:oauth_application, owner: seller)
      create("doorkeeper/access_token",
             application: app,
             resource_owner_id: seller.id,
             scopes: "view_sales",
             resource: Mcp::DynamicClientOauth.resource_identifier("/claude/v1/mcp"),
             created_at: Time.zone.parse("2026-10-02 10:00"))

      get :index

      claude = inertia.props[:clients].first
      expect(claude[:connected]).to eq(true)
      expect(claude[:first_connected_at]).to eq(Time.zone.parse("2026-10-02 10:00").iso8601)
      expect(inertia.props[:clients].drop(1).map { _1[:connected] }).to eq([false, false])
    end

    it "does not gate the page on the sales or payout bar" do
      expect_any_instance_of(User).not_to receive(:sales_cents_total)

      get :index

      expect(response).to be_successful
    end

    context "with a team member whose role may not view the tab" do
      let(:support) { create(:user) }

      before do
        create(:team_membership, user: support, seller:, role: TeamMembership::ROLE_SUPPORT)
        sign_in support
        cookies.encrypted[:current_seller_id] = seller.id
      end

      it "redirects to the dashboard with the role alert" do
        get :index

        expect(response).to redirect_to(dashboard_url)
        expect(flash[:alert]).to eq("Your current role as Support cannot perform this action.")
      end
    end

    context "with an admin team member" do
      let(:admin) { create(:user) }

      before do
        create(:team_membership, user: admin, seller:, role: TeamMembership::ROLE_ADMIN)
        sign_in admin
        cookies.encrypted[:current_seller_id] = seller.id
      end

      it "renders the page" do
        get :index

        expect(response).to be_successful
        expect(inertia).to render_component("Agent/Index")
      end
    end
  end
end
