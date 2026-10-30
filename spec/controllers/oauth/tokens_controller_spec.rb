# frozen_string_literal: true

require "spec_helper"

describe Oauth::TokensController do
  describe "POST create with a refresh_token grant" do
    let(:member) { create(:user) }
    let(:brand) { create(:user) }
    let(:app) { create(:oauth_application, owner: create(:user), confidential: false, scopes: "mobile_api") }
    let(:membership) { create(:team_membership, user: member, seller: brand, role: TeamMembership::ROLE_ADMIN) }

    it "keeps the team membership of a brand token" do
      brand_token = MobileAccountToken.issue!(application: app, scopes: "mobile_api", expires_in: nil, resource_owner: brand, team_membership: membership)

      post :create, params: { grant_type: "refresh_token", refresh_token: brand_token.plaintext_refresh_token, client_id: app.uid }

      expect(response).to have_http_status(:ok)
      refreshed = Doorkeeper::AccessToken.by_token(response.parsed_body["access_token"])
      expect(refreshed).to have_attributes(resource_owner_id: brand.id, team_membership_id: membership.id)
    end

    it "refuses to refresh a brand token once the membership is deleted" do
      brand_token = MobileAccountToken.issue!(application: app, scopes: "mobile_api", expires_in: nil, resource_owner: brand, team_membership: membership)
      membership.update!(deleted_at: Time.current)

      expect do
        post :create, params: { grant_type: "refresh_token", refresh_token: brand_token.plaintext_refresh_token, client_id: app.uid }
      end.not_to change(Doorkeeper::AccessToken, :count)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to eq("invalid_grant")
    end

    it "refuses to refresh a brand token after the member's sessions are invalidated" do
      brand_token = MobileAccountToken.issue!(application: app, scopes: "mobile_api", expires_in: nil, resource_owner: brand, team_membership: membership)
      travel 1.second
      member.invalidate_active_sessions!

      post :create, params: { grant_type: "refresh_token", refresh_token: brand_token.plaintext_refresh_token, client_id: app.uid }

      expect(response.parsed_body["error"]).to eq("invalid_grant")
    end

    it "leaves ordinary tokens without a team membership" do
      token = create("doorkeeper/access_token", application: app, resource_owner_id: member.id, scopes: "mobile_api", use_refresh_token: true)

      post :create, params: { grant_type: "refresh_token", refresh_token: token.refresh_token, client_id: app.uid }

      expect(response).to have_http_status(:ok)
      expect(Doorkeeper::AccessToken.by_token(response.parsed_body["access_token"]).team_membership_id).to be_nil
    end
  end
end
