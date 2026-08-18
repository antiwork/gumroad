# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

describe "Create product mobile app WebView authentication", type: :request, inertia: true do
  include Devise::Test::IntegrationHelpers

  let(:user) { create(:named_seller) }
  let(:oauth_app) { create(:oauth_application, owner: user) }
  let(:access_token) { create("doorkeeper/access_token", application: oauth_app, resource_owner_id: user.id, scopes: "mobile_api") }
  let(:mobile_token) { Api::Mobile::BaseController::MOBILE_TOKEN }

  before do
    create(:user_compliance_info, country: "United States", user:)
    host! DOMAIN
  end

  def inertia_props
    JSON.parse(response.body)["props"]
  end

  context "with ?display=mobile_app, a valid access_token and the correct mobile_token" do
    it "signs the token's user into a web session and flags the Inertia prop" do
      get new_product_path, params: { display: "mobile_app", access_token: access_token.token, mobile_token: }, headers: { "X-Inertia" => "true" }

      expect(response).to be_successful
      expect(inertia_props["is_mobile_app_web_view"]).to eq(true)
    end

    it "establishes a web session so the post-create redirect to the product editor stays authenticated" do
      get new_product_path, params: { display: "mobile_app", access_token: access_token.token, mobile_token: }, headers: { "X-Inertia" => "true" }
      expect(response).to be_successful

      product = create(:product, user:)
      get edit_link_path(product.unique_permalink), headers: { "X-Inertia" => "true" }
      expect(response).to be_successful
      expect(inertia_props["is_mobile_app_web_view"]).to eq(true)
    end
  end

  context "without an access_token" do
    it "redirects to login instead of signing anyone in" do
      get new_product_path

      expect(response).to redirect_to(login_path(next: new_product_path))
    end
  end

  context "with a wrong mobile_token" do
    it "does not sign the user in" do
      get new_product_path, params: { display: "mobile_app", access_token: access_token.token, mobile_token: "wrong_token" }

      expect(response).to have_http_status(:redirect)
      expect(response.location).to include(login_path)
    end
  end

  context "with an access_token that lacks the mobile_api scope" do
    let(:access_token) { create("doorkeeper/access_token", application: oauth_app, resource_owner_id: user.id, scopes: "creator_api") }

    it "is forbidden by doorkeeper and leaks no session on a follow-up request" do
      get new_product_path, params: { display: "mobile_app", access_token: access_token.token, mobile_token: }
      expect(response).to have_http_status(:forbidden)

      get new_product_path
      expect(response.location).to include(login_path)
    end
  end
end
