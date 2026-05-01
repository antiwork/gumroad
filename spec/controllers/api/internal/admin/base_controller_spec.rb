# frozen_string_literal: true

require "spec_helper"

describe Api::Internal::Admin::BaseController do
  controller(described_class) do
    before_action :require_per_actor_token!, only: :create

    def index
      render json: {
        success: true,
        admin_actor_id: Current.admin_actor&.id,
        admin_token_id: Current.admin_token&.id
      }
    end

    def create
      render json: { success: true }
    end
  end

  let(:legacy_admin_actor) { create(:admin_user) }

  before do
    stub_const("GUMROAD_ADMIN_ID", legacy_admin_actor.id)
  end

  describe "admin token authorization" do
    let!(:legacy_admin_token) do
      create(:admin_api_token, actor_user: legacy_admin_actor, token_hash: AdminApiToken.hash_token("test-admin-token"))
    end

    it "allows requests with the configured bearer token" do
      request.headers["Authorization"] = "Bearer test-admin-token"

      get :index

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq({
        success: true,
        admin_actor_id: legacy_admin_actor.id,
        admin_token_id: legacy_admin_token.id
      }.as_json)
    end

    it "allows requests with a per-actor admin token" do
      actor = create(:admin_user)
      plaintext_token = AdminApiToken.mint!(actor_user_id: actor.id)
      admin_api_token = AdminApiToken.find_by!(actor_user: actor, token_hash: AdminApiToken.hash_token(plaintext_token))
      request.headers["Authorization"] = "Bearer #{plaintext_token}"

      get :index

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq({
        success: true,
        admin_actor_id: actor.id,
        admin_token_id: admin_api_token.id
      }.as_json)
      expect(admin_api_token.reload.last_used_at).to be_present
    end

    it "rejects requests with an invalid token" do
      request.headers["Authorization"] = "Bearer invalid-token"

      get :index

      expect(response).to have_http_status(:unauthorized)
      expect(response.body).to eq({ success: false, message: "authorization is invalid" }.to_json)
    end

    it "rejects requests with a revoked per-actor admin token" do
      actor = create(:admin_user)
      plaintext_token = AdminApiToken.mint!(actor_user_id: actor.id)
      admin_api_token = AdminApiToken.find_by!(actor_user: actor, token_hash: AdminApiToken.hash_token(plaintext_token))
      admin_api_token.update!(revoked_at: Time.current)
      request.headers["Authorization"] = "Bearer #{plaintext_token}"

      get :index

      expect(response).to have_http_status(:unauthorized)
      expect(response.body).to eq({ success: false, message: "authorization is invalid" }.to_json)
    end

    it "rejects requests with an expired per-actor admin token" do
      actor = create(:admin_user)
      plaintext_token = AdminApiToken.mint!(actor_user_id: actor.id, expires_at: 1.minute.ago)
      request.headers["Authorization"] = "Bearer #{plaintext_token}"

      get :index

      expect(response).to have_http_status(:unauthorized)
      expect(response.body).to eq({ success: false, message: "authorization is invalid" }.to_json)
    end

    it "rejects malformed authorization headers" do
      request.headers["Authorization"] = "Basic test-admin-token"

      get :index

      expect(response).to have_http_status(:unauthorized)
      expect(response.body).to eq({ success: false, message: "authorization is invalid" }.to_json)
    end

    it "uses the admin token row as the rotation point" do
      request.headers["Authorization"] = "Bearer test-admin-token"

      get :index

      expect(response).to have_http_status(:ok)

      legacy_admin_token.update!(token_hash: AdminApiToken.hash_token("rotated-admin-token"))

      get :index

      expect(response).to have_http_status(:unauthorized)

      request.headers["Authorization"] = "Bearer rotated-admin-token"

      get :index

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["admin_token_id"]).to eq(legacy_admin_token.id)
    end

    it "rejects requests without an authorization header" do
      get :index

      expect(response).to have_http_status(:unauthorized)
      expect(response.body).to eq({ success: false, message: "unauthenticated" }.to_json)
    end
  end

  describe "per-actor admin token requirement" do
    let!(:legacy_admin_token) do
      create(:admin_api_token, actor_user: legacy_admin_actor, token_hash: AdminApiToken.hash_token("test-admin-token"))
    end

    it "allows per-actor admin tokens" do
      actor = create(:admin_user)
      plaintext_token = AdminApiToken.mint!(actor_user_id: actor.id)
      request.headers["Authorization"] = "Bearer #{plaintext_token}"

      post :create

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq({ success: true }.as_json)
    end

    it "rejects the legacy admin token" do
      request.headers["Authorization"] = "Bearer test-admin-token"

      post :create

      expect(response).to have_http_status(:unauthorized)
      expect(response.body).to eq({ success: false, message: "per-actor admin token is required" }.to_json)
    end
  end
end
