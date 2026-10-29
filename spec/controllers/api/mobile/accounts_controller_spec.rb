# frozen_string_literal: true

require "spec_helper"

describe Api::Mobile::AccountsController do
  let(:user) { create(:user, name: "Member") }
  let(:brand) { create(:user, name: "Brand") }
  let(:other_brand) { create(:user, name: "Other brand") }
  let(:app) { create(:oauth_application, owner: create(:user), uid: OauthApplication::MOBILE_API_OAUTH_APPLICATION_UID) }
  let(:token) { create("doorkeeper/access_token", application: app, resource_owner_id: user.id, scopes: "mobile_api creator_api account") }
  let!(:admin_membership) { create(:team_membership, user:, seller: brand, role: TeamMembership::ROLE_ADMIN) }

  def auth_params(access_token = token)
    { mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN, access_token: access_token.token }
  end

  def fresh_controller!
    @controller = described_class.new
  end

  def listed_ids
    response.parsed_body["accounts"].map { _1["id"] }
  end

  describe "GET index" do
    it "lists the user's own account and the brands they administer" do
      get :index, params: auth_params

      expect(response).to be_successful
      expect(response.parsed_body["accounts"]).to eq([
                                                       { "id" => user.external_id, "name" => "Member", "username" => user.username, "avatar_url" => user.avatar_url, "is_active" => true },
                                                       { "id" => brand.external_id, "name" => "Brand", "username" => brand.username, "avatar_url" => brand.avatar_url, "is_active" => false },
                                                     ])
    end

    it "omits deleted memberships" do
      admin_membership.update!(deleted_at: Time.current)

      get :index, params: auth_params

      expect(listed_ids).to eq([user.external_id])
    end

    it "omits brands the user is not a member of" do
      other_brand

      get :index, params: auth_params

      expect(listed_ids).not_to include(other_brand.external_id)
    end

    it "omits brands whose account is deleted" do
      brand.update!(deleted_at: Time.current)

      get :index, params: auth_params

      expect(listed_ids).to eq([user.external_id])
    end

    it "omits memberships without the admin role" do
      create(:team_membership, user:, seller: other_brand, role: TeamMembership::ROLE_MARKETING)

      get :index, params: auth_params

      expect(listed_ids).to eq([user.external_id, brand.external_id])
    end

    it "requires the mobile token" do
      get :index, params: auth_params.merge(mobile_token: "invalid")

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "POST create" do
    it "returns a token pair that authenticates as the target account" do
      post :create, params: auth_params.merge(id: brand.external_id)

      expect(response).to be_successful
      body = response.parsed_body
      expect(body["account"]).to include("id" => brand.external_id, "name" => "Brand", "is_active" => true)
      expect(body["refresh_token"]).to be_present
      issued = Doorkeeper::AccessToken.by_token(body["access_token"])
      expect(issued.resource_owner_id).to eq(brand.id)
      expect(issued.application_id).to eq(app.id)
      expect(issued.scopes.to_a).to match_array(%w[
                                                  mobile_api creator_api view_public
                                                  edit_products view_sales edit_emails view_profile edit_profile
                                                  view_payouts view_tax_data edit_sales refund_sales mark_sales_as_shipped
                                                ])
      expect(issued.team_membership_id).to eq(admin_membership.id)
      expect(admin_membership.reload.last_accessed_at).to be_present

      fresh_controller!
      get :index, params: auth_params(issued)

      expect(response).to be_successful
      expect(response.parsed_body["accounts"].map { _1.slice("id", "is_active") }).to eq([
                                                                                           { "id" => user.external_id, "is_active" => false },
                                                                                           { "id" => brand.external_id, "is_active" => true },
                                                                                         ])
    end

    it "lets a brand token switch back to the member's own account" do
      brand_token = MobileAccountToken.issue!(application: app, scopes: "mobile_api", expires_in: nil, resource_owner: brand, team_membership: admin_membership)

      post :create, params: auth_params(brand_token).merge(id: user.external_id)

      expect(response).to be_successful
      issued = Doorkeeper::AccessToken.by_token(response.parsed_body["access_token"])
      expect(issued.resource_owner_id).to eq(user.id)
      expect(issued.team_membership_id).to be_nil
      expect(issued.scopes.to_a).to match_array(%w[mobile_api creator_api account])
    end

    it "never gives a brand token the `account` scope, which passes every v2 check" do
      post :create, params: auth_params.merge(id: brand.external_id)

      issued = Doorkeeper::AccessToken.by_token(response.parsed_body["access_token"])
      expect(issued.scopes).not_to include("account")
    end

    it "keeps the caller's scopes when the caller switches to its own account" do
      own_token = create("doorkeeper/access_token", application: app, resource_owner_id: user.id, scopes: "mobile_api")

      post :create, params: auth_params(own_token).merge(id: user.external_id)

      issued = Doorkeeper::AccessToken.by_token(response.parsed_body["access_token"])
      expect(issued.scopes.to_s).to eq("mobile_api")
    end

    it "refuses a target the user is not a member of" do
      post :create, params: auth_params.merge(id: other_brand.external_id)

      expect(response).to have_http_status(:forbidden)
      expect(Doorkeeper::AccessToken.where(resource_owner_id: other_brand.id)).not_to exist
    end

    it "refuses a deleted membership" do
      admin_membership.update!(deleted_at: Time.current)

      post :create, params: auth_params.merge(id: brand.external_id)

      expect(response).to have_http_status(:forbidden)
      expect(Doorkeeper::AccessToken.where(resource_owner_id: brand.id)).not_to exist
    end

    it "refuses a membership without the admin role" do
      create(:team_membership, user:, seller: other_brand, role: TeamMembership::ROLE_SUPPORT)

      post :create, params: auth_params.merge(id: other_brand.external_id)

      expect(response).to have_http_status(:forbidden)
    end

    it "returns 404 for an unknown account" do
      post :create, params: auth_params.merge(id: "unknown")

      expect(response).to have_http_status(:not_found)
    end

    it "refuses tokens from other OAuth applications" do
      third_party_token = create("doorkeeper/access_token", application: create(:oauth_application, owner: create(:user)), resource_owner_id: user.id, scopes: "mobile_api")

      post :create, params: auth_params(third_party_token).merge(id: brand.external_id)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "brand tokens" do
    let(:brand_token) { MobileAccountToken.issue!(application: app, scopes: "mobile_api", expires_in: nil, resource_owner: brand, team_membership: admin_membership) }

    it "stop authenticating once the membership is deleted" do
      admin_membership.update!(deleted_at: Time.current)

      get :index, params: auth_params(brand_token)

      expect(response).to have_http_status(:unauthorized)
    end

    it "stop authenticating once the membership loses the admin role" do
      admin_membership.update!(role: TeamMembership::ROLE_MARKETING)

      get :index, params: auth_params(brand_token)

      expect(response).to have_http_status(:unauthorized)
    end

    it "stop authenticating once the member's sessions are invalidated" do
      brand_token
      travel 1.second
      user.invalidate_active_sessions!

      get :index, params: auth_params(brand_token)

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
