# frozen_string_literal: true

require "spec_helper"

describe "Mobile API with a client credentials token", type: :request do
  let(:application) { create(:oauth_application, owner: create(:user), scopes: "mobile_api creator_api") }
  let(:seller) { create(:user) }

  before do
    create(:purchase, link: create(:product, user: seller), seller:, email: "buyer@example.com")
    index_model_records(Purchase)
  end

  def client_credentials_token
    post "https://#{API_DOMAIN}/oauth/token", params: { grant_type: "client_credentials", scope: "mobile_api", client_id: application.uid, client_secret: application.secret }
    expect(response).to have_http_status(:ok)
    response.parsed_body.fetch("access_token")
  end

  it "rejects the token instead of acting without a user" do
    get "https://#{API_DOMAIN}/mobile/sales", params: { mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN, access_token: client_credentials_token }

    expect(response).to have_http_status(:unauthorized)
    expect(response.body).not_to include("buyer@example.com")
  end

  it "still accepts a token issued for a user" do
    token = create("doorkeeper/access_token", application:, resource_owner_id: seller.id, scopes: "mobile_api").token

    get "https://#{API_DOMAIN}/mobile/sales", params: { mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN, access_token: token }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["purchases"].map { _1["email"] }).to eq(["buyer@example.com"])
  end
end
