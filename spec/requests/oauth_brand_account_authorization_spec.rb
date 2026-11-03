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
    post oauth_device_authorization_path, params: { user_code:, decision:, consented_account:, authenticity_token: csrf_token }
  end

  def authorize_code(app, scope)
    get oauth_authorization_path, params: { response_type: "code", client_id: app.uid, redirect_uri: app.redirect_uri, scope: }
    return unless response.ok?

    post oauth_authorization_path, params: { response_type: "code", client_id: app.uid, redirect_uri: app.redirect_uri, scope:, consented_account: consented_account, authenticity_token: csrf_token }
  end

  def consented_account
    Nokogiri::HTML(response.body).at_css("input[name='consented_account']")&.[]("value")
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

    it "offers a way to switch accounts when the selected account needs admin access" do
      membership.update!(role: TeamMembership::ROLE_MARKETING)
      select_account(brand.id)
      body = create_device_code(cli, "view_profile")

      get oauth_device_authorization_path, params: { user_code: body["user_code"] }
      expect(response.body).to include("Switch to your own account")

      get oauth_device_authorization_path, params: { user_code: body["user_code"], switch_account: 1 }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("to use your account?")
      expect(response.body).to include("See your profile data.")
    end

    it "lists only the scopes the brand token will carry" do
      cli.update!(scopes: "view_profile edit_products account")
      select_account(brand.id)
      body = create_device_code(cli, "view_profile account")
      brand_name = brand.display_name(prefer_email_over_default_username: true)

      get oauth_device_authorization_path, params: { user_code: body["user_code"] }

      expect(Nokogiri::HTML(response.body).css("main ul li").map(&:text)).to eq(["See #{brand_name}'s profile data."])
    end

    it "asks again when the selected account changes before the code is approved" do
      other_brand = create(:user)
      create(:team_membership, user: member, seller: other_brand, role: TeamMembership::ROLE_ADMIN)
      select_account(brand.id)
      body = create_device_code(cli, "view_profile")

      get oauth_device_authorization_path, params: { user_code: body["user_code"] }
      approved_account = consented_account
      select_account(other_brand.id)

      post oauth_device_authorization_path, params: { user_code: body["user_code"], decision: "approve", consented_account: approved_account, authenticity_token: csrf_token }

      expect(response).to redirect_to(oauth_device_authorization_path(user_code: body["user_code"]))
      expect(OauthDeviceAuthorization.last).to be_pending
    end

    it "stops the issued token from reaching the API once the membership is removed" do
      select_account(brand.id)
      body = create_device_code(cli, "view_profile")
      decide_device(body["user_code"], "approve")
      travel_to(OauthDeviceAuthorization::POLL_INTERVAL.from_now + 1.second)
      access_token = redeem(cli, body["device_code"])["access_token"]

      get "https://#{API_DOMAIN}/v2/user", params: { access_token: }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("user", "id")).to eq(brand.external_id)

      membership.update_as_deleted!
      get "https://#{API_DOMAIN}/v2/user", params: { access_token: }
      expect(response).to have_http_status(:unauthorized)
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
      expect(response.body).to include("Admin access required")
    end

    it "lets the reader switch to their own account from the 403 page" do
      membership.update!(role: TeamMembership::ROLE_SUPPORT)
      cli.update!(redirect_uri: "http://#{DOMAIN}/")
      sign_in member
      select_account(brand.id)

      get oauth_authorization_path, params: params.merge(redirect_uri: "http://#{DOMAIN}/")
      expect(response.body).to include("Switch to your own account")

      get oauth_authorization_path, params: params.merge(switch_account: 1)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("to use your account?")
      expect(Nokogiri::HTML(response.body).css("ul li").map(&:text)).to include("Create new products and edit your existing products.")
    end

    it "authorizes the reader's own account after switching away from a brand they administer" do
      cli.update!(redirect_uri: "http://#{DOMAIN}/")
      sign_in member
      select_account(brand.id)

      get oauth_authorization_path, params: params.merge(switch_account: 1)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("to use your account?")
      expect(consented_account).to be_blank
    end

    it "does not skip consent for the brand after switching to the reader's own account" do
      cli.update!(redirect_uri: "http://#{DOMAIN}/", confidential: true)
      Doorkeeper::AccessToken.create!(application_id: cli.id, resource_owner_id: brand.id, scopes: params[:scope], team_membership_id: membership.id)
      sign_in member
      select_account(brand.id)

      get oauth_authorization_path, params: params.merge(switch_account: 1)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("to use your account?")
      expect(cli.access_grants.count).to eq(0)
    end

    it "names the selected brand in the consent scope list" do
      cli.update!(redirect_uri: "http://#{DOMAIN}/")
      sign_in member
      select_account(brand.id)
      brand_name = brand.display_name(prefer_email_over_default_username: true)

      get oauth_authorization_path, params: params.merge(redirect_uri: "http://#{DOMAIN}/")

      expect(response).to have_http_status(:ok)
      expect(Nokogiri::HTML(response.body).css("ul li").map(&:text)).to include("Create new products and edit #{brand_name}'s existing products.")
    end

    it "lists only the scopes the brand grant will carry" do
      cli.update!(redirect_uri: "http://#{DOMAIN}/", scopes: "view_profile edit_products account")
      sign_in member
      select_account(brand.id)
      brand_name = brand.display_name(prefer_email_over_default_username: true)

      get oauth_authorization_path, params: params.merge(scope: "edit_products account")

      expect(Nokogiri::HTML(response.body).css("main ul li").map(&:text)).to eq(["Create new products and edit #{brand_name}'s existing products."])
    end

    it "keeps the requested scopes for the member's own account" do
      cli.update!(redirect_uri: "http://#{DOMAIN}/", scopes: "view_profile edit_products account")
      sign_in member

      get oauth_authorization_path, params: params.merge(scope: "edit_products account")

      expect(Nokogiri::HTML(response.body).css("main ul li").map(&:text)).to eq(["Create new products and edit your existing products.", "Full access to your account."])
    end

    it "asks a staff member to stop impersonating instead of offering a switch that cannot change the account" do
      cli.update!(redirect_uri: "http://#{DOMAIN}/")
      admin = create(:admin_user)
      create(:team_membership, user: admin, seller: create(:user), role: TeamMembership::ROLE_ADMIN)
      sign_in admin
      $redis.set(RedisKey.impersonated_user(admin.id), brand.id)

      get oauth_authorization_path, params: params.merge(switch_account: 1)

      expect(response).to have_http_status(:forbidden)
      expect(response.body).to include("Stop impersonating before authorizing an OAuth application.")
      expect(response.body).not_to include("Switch to your own account")
      expect(cli.access_grants.count).to eq(0)
    ensure
      $redis.del(RedisKey.impersonated_user(admin.id)) if defined?(admin) && admin&.persisted?
    end

    it "asks again when the selected account changes before the page is approved" do
      cli.update!(redirect_uri: "http://#{DOMAIN}/")
      other_brand = create(:user)
      create(:team_membership, user: member, seller: other_brand, role: TeamMembership::ROLE_ADMIN)
      sign_in member
      select_account(brand.id)

      get oauth_authorization_path, params: params
      approved_account = consented_account
      select_account(other_brand.id)

      post oauth_authorization_path, params: params.merge(consented_account: approved_account, authenticity_token: csrf_token)

      expect(response).to redirect_to(%r{/oauth/authorize})
      expect(cli.access_grants.count).to eq(0)
    end
  end

  describe "revoking a connection from the settings page" do
    let(:params) { { response_type: "code", client_id: cli.uid, redirect_uri: "http://#{DOMAIN}/", scope: "edit_products" } }

    around do |example|
      previous_forgery = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = false
      example.run
    ensure
      ActionController::Base.allow_forgery_protection = previous_forgery
    end

    it "revokes the account selected in the switcher" do
      cli.update!(redirect_uri: "http://#{DOMAIN}/")
      sign_in member
      select_account(brand.id)
      token = authorized_brand_token

      delete oauth_authorized_application_path(cli.external_id)

      expect(response).to redirect_to(settings_authorized_applications_path)
      expect(token.reload.revoked_at).to be_present
    end

    it "leaves a connection belonging to an account the member does not administer" do
      cli.update!(redirect_uri: "http://#{DOMAIN}/")
      sign_in member
      select_account(brand.id)
      token = authorized_brand_token
      membership.update!(role: TeamMembership::ROLE_SUPPORT)

      delete oauth_authorized_application_path(cli.external_id)

      expect(token.reload.revoked_at).to be_nil
    end

    def authorized_brand_token
      authorize_code(cli, params[:scope])
      post oauth_token_path, params: { grant_type: "authorization_code", code: cli.access_grants.last.plaintext_token, client_id: cli.uid, redirect_uri: cli.redirect_uri }
      Doorkeeper::AccessToken.find_by_token(response.parsed_body["access_token"])
    end
  end

  def stub_vite_layout_helpers
    allow(ViteRuby.instance.manifest).to receive(:resolve_entries).and_return({ stylesheets: ["/vite-test.css"] })
    allow_any_instance_of(ActionView::Base).to receive(:vite_client_tag).and_return("")
    allow_any_instance_of(ActionView::Base).to receive(:vite_react_refresh_tag).and_return("")
    allow_any_instance_of(ActionView::Base).to receive(:vite_typescript_tag).and_return("")
  end
end
