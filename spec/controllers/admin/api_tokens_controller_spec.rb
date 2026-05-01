# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

describe Admin::ApiTokensController, type: :controller, inertia: true do
  render_views

  let(:admin_user) { create(:admin_user) }

  before do
    sign_in admin_user
  end

  describe "GET index" do
    it "lists active admin API tokens with actor and type" do
      _plaintext_token, active_token = AdminApiToken.mint_with_plaintext!(actor_user_id: admin_user.id, expires_at: 30.days.from_now)
      _service_plaintext_token, service_token = AdminApiToken.mint_with_plaintext!(actor_user_id: admin_user.id)
      _expired_plaintext_token, expired_token = AdminApiToken.mint_with_plaintext!(actor_user_id: admin_user.id, expires_at: 1.day.ago)
      _revoked_plaintext_token, revoked_token = AdminApiToken.mint_with_plaintext!(actor_user_id: admin_user.id, expires_at: 30.days.from_now)
      _other_plaintext_token, other_admin_token = AdminApiToken.mint_with_plaintext!(actor_user_id: create(:admin_user).id, expires_at: 30.days.from_now)
      legacy_token = create_legacy_admin_token
      revoked_token.update!(revoked_at: Time.current)
      expect(AdminApiToken).to receive(:legacy_admin_token).once.and_call_original

      get :index

      expect(response).to have_http_status(:ok)
      expect(inertia.component).to eq "Admin/ApiTokens/Index"
      expect(inertia.props[:title]).to eq("Admin API tokens")
      expect(inertia.props[:tokens]).to match_array([
                                                      serialized_token(active_token, kind: "CLI"),
                                                      serialized_token(service_token, kind: "Service"),
                                                      serialized_token(other_admin_token, kind: "CLI"),
                                                      serialized_legacy_token(legacy_token)
                                                    ])
      expect(inertia.props[:tokens].pluck(:external_id)).not_to include(expired_token.external_id, revoked_token.external_id)
    end
  end

  describe "POST revoke" do
    it "revokes an active admin API token for any actor" do
      _plaintext_token, admin_api_token = AdminApiToken.mint_with_plaintext!(actor_user_id: create(:admin_user).id)

      post :revoke, params: { external_id: admin_api_token.external_id }

      expect(response).to redirect_to(admin_api_tokens_path)
      expect(response).to have_http_status(:see_other)
      expect(flash[:notice]).to eq("Admin API token revoked.")
      expect(admin_api_token.reload.revoked_at).to be_present
    end

    it "does not revoke an inactive token" do
      _plaintext_token, admin_api_token = AdminApiToken.mint_with_plaintext!(actor_user_id: admin_user.id, expires_at: 1.day.ago)

      post :revoke, params: { external_id: admin_api_token.external_id }

      expect(response).to redirect_to(admin_api_tokens_path)
      expect(flash[:alert]).to eq("Active admin API token not found.")
      expect(admin_api_token.reload.revoked_at).to be_nil
    end
  end

  def serialized_token(admin_api_token, kind:)
    actor_user = admin_api_token.actor_user
    {
      external_id: admin_api_token.external_id,
      actor: {
        id: actor_user.id,
        name: actor_user.name,
        email: actor_user.email
      },
      kind:,
      created_at: admin_api_token.created_at.as_json,
      last_used_at: nil,
      expires_at: admin_api_token.expires_at&.as_json,
      revoke_path: revoke_admin_api_token_path(admin_api_token.external_id)
    }
  end

  def serialized_legacy_token(admin_api_token)
    {
      external_id: admin_api_token.external_id,
      actor: {
        id: nil,
        name: "Legacy internal admin token",
        email: nil
      },
      kind: "Legacy",
      created_at: admin_api_token.created_at.as_json,
      last_used_at: nil,
      expires_at: nil,
      revoke_path: revoke_admin_api_token_path(admin_api_token.external_id)
    }
  end

  def create_legacy_admin_token
    legacy_actor_id = User.maximum(:id).to_i + 1_000_000
    stub_const("GUMROAD_ADMIN_ID", legacy_actor_id)

    external_id = AdminApiToken.generate_token(AdminApiToken::EXTERNAL_ID_LENGTH)
    AdminApiToken.insert!(
      {
        external_id:,
        actor_user_id: legacy_actor_id,
        token_hash: AdminApiToken.hash_token("legacy-admin-token-#{SecureRandom.uuid}"),
        created_at: Time.current,
        updated_at: Time.current
      }
    )
    AdminApiToken.find_by!(external_id:)
  end
end
