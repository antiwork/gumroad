# frozen_string_literal: true

require "test_helper"

class ApiInternalAdminAuthControllerTest < ActionController::TestCase
  self.described_class = Api::Internal::Admin::AuthController
  tests Api::Internal::Admin::AuthController



  context_ Api::Internal::Admin::AuthController do
  context_ "POST exchange" do
  test "exchanges a valid authorization code for a human admin token" do
        actor = create(:admin_user, name: "Admin User", email: "admin@example.com")
        plaintext_code = "authorization-code"
        code_verifier = "code-verifier"
        create(:admin_api_authorization_code, actor_user: actor, plaintext_code:, code_verifier:)

        post :exchange, params: { code: plaintext_code, code_verifier: }

        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        admin_api_token = AdminApiToken.authenticate(body["token"])
        expect(admin_api_token).to have_attributes(
          actor_user: actor,
          external_id: body["token_external_id"],
          expires_at: be_present
        )
        expect(body["expires_at"]).to eq(admin_api_token.expires_at.as_json)
        expect(body["actor"]).to eq({
                                      "external_id" => actor.external_id,
                                      "name" => "Admin User",
                                      "email" => "admin@example.com"
                                    })
      end

  test "rejects single-use codes after the first exchange" do
        plaintext_code = "authorization-code"
        code_verifier = "code-verifier"
        create(:admin_api_authorization_code, plaintext_code:, code_verifier:)

        post :exchange, params: { code: plaintext_code, code_verifier: }
        expect(response).to have_http_status(:ok)

        expect do
          post :exchange, params: { code: plaintext_code, code_verifier: }
        end.not_to change(AdminApiToken, :count)
        expect(response).to have_http_status(:unauthorized)
        expect(response.parsed_body).to eq({ "success" => false, "message" => "authorization code is invalid" })
      end

  test "rejects expired codes and PKCE mismatches" do
        create(:admin_api_authorization_code, plaintext_code: "expired-code", expires_at: 1.second.ago)
        create(:admin_api_authorization_code, plaintext_code: "pkce-code", code_verifier: "expected")

        post :exchange, params: { code: "expired-code", code_verifier: "test-code-verifier" }
        expect(response).to have_http_status(:unauthorized)

        post :exchange, params: { code: "pkce-code", code_verifier: "wrong" }
        expect(response).to have_http_status(:unauthorized)
      end
    end

  context_ "POST revoke" do
  test "revokes the bearer token when no external id is provided" do
        plaintext_token, admin_api_token = AdminApiToken.mint_with_plaintext!(actor_user_id: create(:admin_user).id, expires_at: 30.days.from_now)
        request.headers["Authorization"] = "Bearer #{plaintext_token}"

        post :revoke

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to eq({ "success" => true })
        expect(admin_api_token.reload.revoked_at).to be_present
      end

  test "revokes another token belonging to the same actor" do
        actor = create(:admin_user)
        bearer_plaintext_token, bearer_token = AdminApiToken.mint_with_plaintext!(actor_user_id: actor.id, expires_at: 30.days.from_now)
        other_plaintext_token, other_token = AdminApiToken.mint_with_plaintext!(actor_user_id: actor.id, expires_at: 30.days.from_now)
        request.headers["Authorization"] = "Bearer #{bearer_plaintext_token}"

        post :revoke, params: { external_id: other_token.external_id }

        expect(response).to have_http_status(:ok)
        expect(bearer_token.reload.revoked_at).to be_nil
        expect(other_token.reload.revoked_at).to be_present
        expect(AdminApiToken.authenticate(other_plaintext_token)).to be_nil
      end

  test "records an audit log when revoking another token" do
        actor = create(:admin_user)
        bearer_plaintext_token, bearer_token = AdminApiToken.mint_with_plaintext!(actor_user_id: actor.id, expires_at: 30.days.from_now)
        _other_plaintext_token, other_token = AdminApiToken.mint_with_plaintext!(actor_user_id: actor.id, expires_at: 30.days.from_now)
        request.headers["Authorization"] = "Bearer #{bearer_plaintext_token}"

        expect do
          post :revoke, params: { external_id: other_token.external_id }
        end.to change { AdminApiAuditLog.count }.by(1)

        expect(AdminApiAuditLog.last).to have_attributes(
          action: "auth.revoke",
          target_type: "AdminApiToken",
          target_id: other_token.id,
          target_external_id: other_token.external_id,
          actor_user_id: actor.id,
          admin_api_token_id: bearer_token.id,
          response_status: 200
        )
        expect(AdminApiAuditLog.last.params_snapshot).to include("external_id" => other_token.external_id)
      end

  test "does not revoke another actor's token" do
        bearer_plaintext_token, = AdminApiToken.mint_with_plaintext!(actor_user_id: create(:admin_user).id, expires_at: 30.days.from_now)
        _other_plaintext_token, other_token = AdminApiToken.mint_with_plaintext!(actor_user_id: create(:admin_user).id, expires_at: 30.days.from_now)
        request.headers["Authorization"] = "Bearer #{bearer_plaintext_token}"

        post :revoke, params: { external_id: other_token.external_id }

        expect(response).to have_http_status(:not_found)
        expect(response.parsed_body).to eq({ "success" => false, "message" => "admin token not found" })
        expect(other_token.reload.revoked_at).to be_nil
      end
    end
  end
end
