# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_oauth_v1_api_method"

describe Api::V2::MetaController do
  before do
    @user = create(:user, email: "creator@example.com")
    @app = create(:oauth_application, name: "Acme Agent", owner: create(:user))
  end

  describe "GET 'show'" do
    before do
      @action = :show
      @params = {}
    end

    it_behaves_like "authorized oauth v1 api method"

    it "returns the token scopes, application name, user external_id, and api metadata" do
      token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_sales edit_products")

      get @action, params: { access_token: token.token }

      expect(response).to be_successful
      body = response.parsed_body
      expect(body["success"]).to eq(true)
      expect(body["user"]).to eq("id" => @user.external_id)
      expect(body["token"]["scopes"]).to match_array(%w[view_sales edit_products])
      expect(body["token"]["application_name"]).to eq("Acme Agent")
      expect(body["api"]).to eq("version" => "v2", "documentation_url" => "https://app.gumroad.com/api")
    end

    it "accepts the default view_public scope" do
      token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_public")

      get @action, params: { access_token: token.token }

      expect(response).to be_successful
      expect(response.parsed_body["token"]["scopes"]).to eq(["view_public"])
    end

    it "accepts the account scope" do
      token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "account")

      get @action, params: { access_token: token.token }

      expect(response).to be_successful
      expect(response.parsed_body["token"]["scopes"]).to eq(["account"])
    end

    it "rejects a token whose scope is not recognized" do
      token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "mobile_api")

      get @action, params: { access_token: token.token }

      expect(response.status).to eq(403)
    end
  end
end
