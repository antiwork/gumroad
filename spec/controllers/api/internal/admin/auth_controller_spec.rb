# frozen_string_literal: true

require "spec_helper"

describe Api::Internal::Admin::AuthController do
  describe "POST exchange" do
    it "exchanges a valid authorization code for a human admin token" do
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

    it "rejects single-use codes after the first exchange" do
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

    it "rejects expired codes and PKCE mismatches" do
      create(:admin_api_authorization_code, plaintext_code: "expired-code", expires_at: 1.second.ago)
      create(:admin_api_authorization_code, plaintext_code: "pkce-code", code_verifier: "expected")

      post :exchange, params: { code: "expired-code", code_verifier: "test-code-verifier" }
      expect(response).to have_http_status(:unauthorized)

      post :exchange, params: { code: "pkce-code", code_verifier: "wrong" }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "POST revoke" do
    it "revokes the bearer token when no external id is provided" do
      plaintext_token, admin_api_token = AdminApiToken.mint_with_plaintext!(actor_user_id: create(:admin_user).id, expires_at: 30.days.from_now)
      request.headers["Authorization"] = "Bearer #{plaintext_token}"

      post :revoke

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq({ "success" => true })
      expect(admin_api_token.reload.revoked_at).to be_present
    end

    it "revokes another token belonging to the same actor" do
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

    it "records an audit log when revoking another token" do
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

    it "does not revoke another actor's admin token" do
      bearer_plaintext_token, = AdminApiToken.mint_with_plaintext!(actor_user_id: create(:admin_user).id, expires_at: 30.days.from_now)
      _other_plaintext_token, other_token = AdminApiToken.mint_with_plaintext!(actor_user_id: create(:admin_user).id, expires_at: 30.days.from_now)
      request.headers["Authorization"] = "Bearer #{bearer_plaintext_token}"

      post :revoke, params: { external_id: other_token.external_id }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ "success" => false, "message" => "admin token not found" })
      expect(other_token.reload.revoked_at).to be_nil
    end

    it "revokes a service token belonging to another actor, and the token stops authenticating" do
      bearer_plaintext_token, = AdminApiToken.mint_with_plaintext!(actor_user_id: create(:admin_user).id, expires_at: 30.days.from_now)
      agent_plaintext_token, agent_token = AdminApiToken.mint_with_plaintext!(actor_user_id: create(:admin_user).id, scope: AdminApiToken::PIRACY_SCOPE)
      request.headers["Authorization"] = "Bearer #{bearer_plaintext_token}"

      post :revoke, params: { external_id: agent_token.external_id }

      expect(response).to have_http_status(:ok)
      expect(agent_token.reload.revoked_at).to be_present
      expect(AdminApiToken.authenticate(agent_plaintext_token)).to be_nil
    end

    it "refuses a service token, so the agent cannot manage tokens" do
      plaintext_token, = AdminApiToken.mint_with_plaintext!(actor_user_id: create(:admin_user).id, scope: AdminApiToken::PIRACY_SCOPE)
      request.headers["Authorization"] = "Bearer #{plaintext_token}"

      post :revoke

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST rotate" do
    it "replaces a service token with a working token for the same actor and scope" do
      bearer_plaintext_token, = AdminApiToken.mint_with_plaintext!(actor_user_id: create(:admin_user).id, expires_at: 30.days.from_now)
      agent_actor = create(:admin_user)
      agent_plaintext_token, agent_token = AdminApiToken.mint_with_plaintext!(actor_user_id: agent_actor.id, scope: AdminApiToken::PIRACY_SCOPE)
      request.headers["Authorization"] = "Bearer #{bearer_plaintext_token}"

      post :rotate, params: { external_id: agent_token.external_id }

      expect(response).to have_http_status(:ok)
      replacement = AdminApiToken.authenticate(response.parsed_body["token"])
      expect(replacement).to have_attributes(actor_user: agent_actor, scope: AdminApiToken::PIRACY_SCOPE)
      expect(response.parsed_body["token_external_id"]).to eq(replacement.external_id)
      expect(agent_token.reload.revoked_at).to be_present
      expect(AdminApiToken.authenticate(agent_plaintext_token)).to be_nil
    end

    it "records an audit log for the rotation" do
      bearer_plaintext_token, bearer_token = AdminApiToken.mint_with_plaintext!(actor_user_id: create(:admin_user).id, expires_at: 30.days.from_now)
      _agent_plaintext_token, agent_token = AdminApiToken.mint_with_plaintext!(actor_user_id: create(:admin_user).id, scope: AdminApiToken::PIRACY_SCOPE)
      request.headers["Authorization"] = "Bearer #{bearer_plaintext_token}"

      expect do
        post :rotate, params: { external_id: agent_token.external_id }
      end.to change { AdminApiAuditLog.count }.by(1)

      expect(AdminApiAuditLog.last).to have_attributes(
        action: "auth.rotate",
        target_type: "AdminApiToken",
        target_id: agent_token.id,
        target_external_id: agent_token.external_id,
        admin_api_token_id: bearer_token.id,
        response_status: 200
      )
    end

    it "does not rotate another actor's admin token" do
      bearer_plaintext_token, = AdminApiToken.mint_with_plaintext!(actor_user_id: create(:admin_user).id, expires_at: 30.days.from_now)
      other_plaintext_token, other_token = AdminApiToken.mint_with_plaintext!(actor_user_id: create(:admin_user).id, expires_at: 30.days.from_now)
      request.headers["Authorization"] = "Bearer #{bearer_plaintext_token}"

      post :rotate, params: { external_id: other_token.external_id }

      expect(response).to have_http_status(:not_found)
      expect(other_token.reload.revoked_at).to be_nil
      expect(AdminApiToken.authenticate(other_plaintext_token)).to be_present
    end

    it "refuses to rotate a token that expires and says to revoke it instead" do
      plaintext_token, admin_api_token = AdminApiToken.mint_with_plaintext!(actor_user_id: create(:admin_user).id, expires_at: 30.days.from_now)
      request.headers["Authorization"] = "Bearer #{plaintext_token}"

      expect { post :rotate }.not_to change { AdminApiToken.count }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq({ "success" => false, "message" => "only a token without an expiry can be rotated; revoke it instead" })
      expect(admin_api_token.reload.revoked_at).to be_nil
    end

    it "does not rotate an already revoked token" do
      bearer_plaintext_token, = AdminApiToken.mint_with_plaintext!(actor_user_id: create(:admin_user).id, expires_at: 30.days.from_now)
      _agent_plaintext_token, agent_token = AdminApiToken.mint_with_plaintext!(actor_user_id: create(:admin_user).id, scope: AdminApiToken::PIRACY_SCOPE)
      agent_token.revoke!
      request.headers["Authorization"] = "Bearer #{bearer_plaintext_token}"

      post :rotate, params: { external_id: agent_token.external_id }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq({ "success" => false, "message" => "admin token not found" })
    end
  end
end
