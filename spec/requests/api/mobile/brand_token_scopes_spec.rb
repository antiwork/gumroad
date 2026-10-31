# frozen_string_literal: true

require "spec_helper"

describe "Mobile brand token scopes", type: :request do
  let(:member) { create(:user) }
  let(:brand) { create(:user) }
  let(:oauth_app) { create(:oauth_application, owner: create(:user), uid: OauthApplication::MOBILE_API_OAUTH_APPLICATION_UID) }
  let(:member_token) { create("doorkeeper/access_token", application: oauth_app, resource_owner_id: member.id, scopes: "mobile_api creator_api account") }
  let!(:membership) { create(:team_membership, user: member, seller: brand, role: TeamMembership::ROLE_ADMIN) }

  def api_url(path) = "https://#{API_DOMAIN}#{path}"

  def switch_to(account, token: member_token)
    post api_url("/mobile/accounts"), params: { mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN, access_token: token.token, id: account.external_id }
    expect(response).to have_http_status(:ok)
    Doorkeeper::AccessToken.by_token(response.parsed_body["access_token"])
  end

  it "reaches the v2 endpoints the member's role allows on the brand" do
    brand_token = switch_to(brand)

    get api_url("/v2/sales"), params: { access_token: brand_token.token }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["success"]).to be(true)
  end

  it "passes the app's minimum-version check" do
    brand_token = switch_to(brand)

    get api_url("/internal/mobile_minimum_version"), params: { access_token: brand_token.token }

    expect(response).to have_http_status(:ok)
  end

  it "is refused by a v2 endpoint whose scope the role does not grant, which a copied `account` scope would pass" do
    brand_token = switch_to(brand)
    product = create(:product, user: brand)
    uri = "#{brand.subdomain_with_protocol}/l/#{product.unique_permalink}"

    host! DOMAIN
    post "/notion/unfurl", params: { access_token: brand_token.token, uri: }
    expect(response).to have_http_status(:forbidden)

    account_token = create("doorkeeper/access_token", application: oauth_app, resource_owner_id: brand.id, scopes: "account")
    post "/notion/unfurl", params: { access_token: account_token.token, uri: }
    expect(response).to have_http_status(:ok)
  end

  it "restores the member's own scopes when switching back from the brand" do
    brand_token = switch_to(brand)

    own_token = switch_to(member, token: brand_token)

    expect(own_token.resource_owner_id).to eq(member.id)
    expect(own_token.scopes.to_a).to match_array(%w[mobile_api creator_api account])
  end
end
