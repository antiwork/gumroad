# frozen_string_literal: true

require "spec_helper"

describe "CatchBadRequestErrors middleware" do
  let!(:user) { create(:user) }
  let!(:oauth_application) { create(:oauth_application, owner: user) }

  context "when a request contains invalid params" do
    it "returns 400 (Bad Request) response" do
      post oauth_token_path, params: "hello-%"

      expect(response).to have_http_status(:bad_request)
      expect(response.body).to eq("")
    end

    it "returns error JSON response with 400 (Bad Request) status for a JSON request" do
      post oauth_token_path, params: "hello-%", headers: { "ACCEPT" => "application/json" }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["success"]).to eq(false)
    end
  end

  context "when a request contains valid params" do
    it "returns 200 (OK) response" do
      post oauth_token_path, params: { grant_type: "password", scope: "edit_products", username: user.email, password: user.password, client_id: oauth_application.uid, client_secret: oauth_application.secret }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.keys).to match_array(%w(access_token created_at refresh_token scope token_type))
    end
  end
end
