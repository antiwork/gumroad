# frozen_string_literal: true

require "spec_helper"

describe "OAuth authorization for a brand account", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:member) { create(:user) }
  let(:brand) { create(:user) }
  let!(:membership) { create(:team_membership, user: member, seller: brand, role: TeamMembership::ROLE_ADMIN) }
  let(:cli) { create(:oauth_application, owner: member, name: "Gumroad CLI", scopes: "view_profile edit_products view_payouts", confidential: false, device_authorization_enabled: true) }
  let(:other_app) { create(:oauth_application, owner: member, redirect_uri: "http://#{DOMAIN}/", scopes: "edit_products", confidential: false) }

  before do
    host! DOMAIN
    stub_vite_layout_helpers
  end

  def select_account(seller_id)
    allow_any_instance_of(CurrentSeller).to receive(:find_seller_from_cookie).and_return(User.find(seller_id))
  end

  def create_device_code(app, scope)
    post oauth_device_code_path, params: { client_id: app.uid, scope: }
    body = response.parsed_body
    sign_in member
    body
  end

  def csrf_token
    doc = Nokogiri::HTML(response.body)
    node = doc.at_css("input[name='authenticity_token']") || doc.at_css("meta[name='csrf-token']")
    node["value"] || node["content"]
  end

  def decide_device(user_code, decision)
    get oauth_device_authorization_path, params: { user_code: }
    post oauth_device_authorization_path, params: { user_code:, decision:, authenticity_token: csrf_token }
  end

  def authorize_code(app, scope)
    get oauth_authorization_path, params: { response_type: "code", client_id: app.uid, redirect_uri: app.redirect_uri, scope: }
    return unless response.ok?

    post oauth_authorization_path, params: { response_type: "code", client_id: app.uid, redirect_uri: app.redirect_uri, scope:, authenticity_token: csrf_token }
  end

  def redeem(app, device_code)
    post oauth_token_path, params: { grant_type: OauthDeviceAuthorization::GRANT_TYPE, client_id: app.uid, device_code: }
    response.parsed_body
  end

  describe "device flow (CLI)" do
    it "binds the token to the selected brand and narrows scopes to the member's role" do
      select_account(brand.id)
      body = create_device_code(cli, "view_profile edit_products")

      get oauth_device_authorization_path, params: { user_code: body["user_code"] }
      expect(response.body).to include(brand.display_name(prefer_email_over_default_username: true))

      decide_device(body["user_code"], "approve")
      travel_to(OauthDeviceAuthorization::POLL_INTERVAL.from_now + 1.second)
      token = Doorkeeper::AccessToken.find_by_token(redeem(cli, body["device_code"])["access_token"])

      expect(token).to have_attributes(resource_owner_id: brand.id, team_membership_id: membership.id)
      expect(token.scopes.to_a).to match_array(%w[view_profile edit_products])
    end

    it "keeps binding to the signed-in user when their own account is selected" do
      body = create_device_code(cli, "view_profile")
      decide_device(body["user_code"], "approve")
      travel_to(OauthDeviceAuthorization::POLL_INTERVAL.from_now + 1.second)
      token = Doorkeeper::AccessToken.find_by_token(redeem(cli, body["device_code"])["access_token"])

      expect(token).to have_attributes(resource_owner_id: member.id, team_membership_id: nil)
    end

    it "refuses to authorize a selected account the user does not administer" do
      membership.update!(role: TeamMembership::ROLE_MARKETING)
      select_account(brand.id)
      body = create_device_code(cli, "view_profile")

      decide_device(body["user_code"], "approve")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(OauthDeviceAuthorization.last).to be_pending
    end

    it "stops issuing once the membership is removed before the CLI redeems" do
      select_account(brand.id)
      body = create_device_code(cli, "view_profile")
      decide_device(body["user_code"], "approve")
      membership.update_as_deleted!
      travel_to(OauthDeviceAuthorization::POLL_INTERVAL.from_now + 1.second)

      expect(redeem(cli, body["device_code"])).to include("error" => "access_denied")
    end
  end

  describe "authorization code flow" do
    let(:params) { { response_type: "code", client_id: cli.uid, redirect_uri: cli.redirect_uri, scope: "edit_products view_payouts" } }

    it "issues a grant bound to the selected brand and an exchanged token that carries the membership" do
      cli.update!(redirect_uri: "http://#{DOMAIN}/")
      sign_in member
      select_account(brand.id)

      authorize_code(cli, params[:scope])
      grant = cli.access_grants.last
      expect(grant).to have_attributes(resource_owner_id: brand.id, team_membership_id: membership.id)

      post oauth_token_path, params: { grant_type: "authorization_code", code: grant.plaintext_token, client_id: cli.uid, redirect_uri: cli.redirect_uri }
      token = Doorkeeper::AccessToken.find_by_token(response.parsed_body["access_token"])
      expect(token).to have_attributes(resource_owner_id: brand.id, team_membership_id: membership.id)
    end

    it "refuses the code exchange after the membership is removed" do
      cli.update!(redirect_uri: "http://#{DOMAIN}/")
      sign_in member
      select_account(brand.id)
      authorize_code(cli, params[:scope])
      grant = cli.access_grants.last
      membership.update_as_deleted!

      post oauth_token_path, params: { grant_type: "authorization_code", code: grant.plaintext_token, client_id: cli.uid, redirect_uri: cli.redirect_uri }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to include("error" => "invalid_grant")
    end

    it "does not follow the switcher for other applications" do
      sign_in member
      select_account(brand.id)

      authorize_code(other_app, "edit_products")

      expect(other_app.access_grants.last).to have_attributes(resource_owner_id: member.id, team_membership_id: nil)
    end

    it "refuses consent for a selected account the user does not administer" do
      membership.update!(role: TeamMembership::ROLE_SUPPORT)
      sign_in member
      select_account(brand.id)

      get oauth_authorization_path, params: params.merge(redirect_uri: "http://#{DOMAIN}/")

      expect(response).to have_http_status(:forbidden)
    end
  end

  def stub_vite_layout_helpers
    allow(ViteRuby.instance.manifest).to receive(:resolve_entries).and_return({ stylesheets: ["/vite-test.css"] })
    allow_any_instance_of(ActionView::Base).to receive(:vite_client_tag).and_return("")
    allow_any_instance_of(ActionView::Base).to receive(:vite_react_refresh_tag).and_return("")
    allow_any_instance_of(ActionView::Base).to receive(:vite_typescript_tag).and_return("")
  end
end
