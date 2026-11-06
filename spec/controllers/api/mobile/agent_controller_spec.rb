# frozen_string_literal: true

require "spec_helper"

describe Api::Mobile::AgentController do
  before do
    @seller = create(:user)
    @app = create(:oauth_application, owner: @seller)
    @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "mobile_api")
    @auth_params = { mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN, access_token: @token.token }
  end

  describe "GET meta" do
    it "tells shipped app builds the chat is gone and where to connect an AI instead" do
      get :meta, params: @auth_params

      expect(response).to be_successful
      expect(response.parsed_body).to eq(
        "success" => true,
        "enabled" => false,
        "greeting" => "",
        "suggestions" => [],
        "available" => false,
        "notice" => "The Agent tab is gone. Connect Claude or ChatGPT to your store at gumroad.com/mcp.",
      )
    end

    it "rejects a request with an invalid mobile token" do
      get :meta, params: @auth_params.merge(mobile_token: "invalid_token")

      expect(response.status).to be(401)
    end

    it "rejects a request with an invalid access token" do
      get :meta, params: @auth_params.merge(access_token: "invalid_token")

      expect(response.status).to be(401)
    end
  end
end
