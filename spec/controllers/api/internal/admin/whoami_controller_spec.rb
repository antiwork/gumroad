# frozen_string_literal: true

require "spec_helper"

describe Api::Internal::Admin::WhoamiController do
  describe "GET show" do
    it "returns the authenticated admin actor and token metadata" do
      actor = create(:admin_user, name: "Admin User", email: "admin@example.com")
      plaintext_token, admin_api_token = AdminApiToken.mint_with_plaintext!(actor_user_id: actor.id, expires_at: 30.days.from_now)
      request.headers["Authorization"] = "Bearer #{plaintext_token}"

      get :show

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq({
                                           "actor" => {
                                             "external_id" => actor.external_id,
                                             "name" => "Admin User",
                                             "email" => "admin@example.com"
                                           },
                                           "token" => {
                                             "external_id" => admin_api_token.external_id,
                                             "expires_at" => admin_api_token.reload.expires_at.as_json
                                           },
                                           "scopes" => ["admin"]
                                         })
    end

    it "returns a placeholder actor for the legacy admin token" do
      actor = create(:admin_user, name: "Admin User", email: "admin@example.com")
      stub_const("GUMROAD_ADMIN_ID", actor.id)
      plaintext_token = "legacy-admin-token"
      admin_api_token = create(:admin_api_token, actor_user: actor, token_hash: AdminApiToken.hash_token(plaintext_token))
      request.headers["Authorization"] = "Bearer #{plaintext_token}"

      get :show

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq({
                                           "actor" => {
                                             "external_id" => nil,
                                             "name" => "Legacy internal admin token",
                                             "email" => nil
                                           },
                                           "token" => {
                                             "external_id" => admin_api_token.external_id,
                                             "expires_at" => nil
                                           },
                                           "scopes" => ["admin"]
                                         })
    end
  end
end
