# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

describe Admin::Cli::TokensController, type: :controller, inertia: true do
  render_views

  let(:admin_user) { create(:admin_user) }

  before do
    sign_in admin_user
  end

  describe "GET index" do
    it "lists active human CLI tokens for the current admin" do
      _plaintext_token, active_token = AdminApiToken.mint_with_plaintext!(actor_user_id: admin_user.id, expires_at: 30.days.from_now)
      _revoked_plaintext_token, revoked_token = AdminApiToken.mint_with_plaintext!(actor_user_id: admin_user.id, expires_at: 30.days.from_now)
      _service_plaintext_token, = AdminApiToken.mint_with_plaintext!(actor_user_id: admin_user.id)
      _other_plaintext_token, = AdminApiToken.mint_with_plaintext!(actor_user_id: create(:admin_user).id, expires_at: 30.days.from_now)
      revoked_token.update!(revoked_at: Time.current)

      get :index

      expect(response).to have_http_status(:ok)
      expect(inertia.component).to eq "Admin/Cli/Tokens/Index"
      expect(inertia.props[:title]).to eq("CLI tokens")
      expect(inertia.props[:tokens]).to eq([
                                             {
                                               external_id: active_token.external_id,
                                               created_at: active_token.created_at.as_json,
                                               last_used_at: nil,
                                               expires_at: active_token.expires_at.as_json,
                                               revoke_path: revoke_admin_cli_token_path(active_token.external_id)
                                             }
                                           ])
    end
  end

  describe "POST revoke" do
    it "revokes a current admin CLI token" do
      _plaintext_token, admin_api_token = AdminApiToken.mint_with_plaintext!(actor_user_id: admin_user.id, expires_at: 30.days.from_now)

      post :revoke, params: { external_id: admin_api_token.external_id }

      expect(response).to redirect_to(admin_cli_tokens_path)
      expect(response).to have_http_status(:see_other)
      expect(flash[:notice]).to eq("CLI token revoked.")
      expect(admin_api_token.reload.revoked_at).to be_present
    end

    it "does not revoke another admin's token" do
      _plaintext_token, admin_api_token = AdminApiToken.mint_with_plaintext!(actor_user_id: create(:admin_user).id, expires_at: 30.days.from_now)

      post :revoke, params: { external_id: admin_api_token.external_id }

      expect(response).to redirect_to(admin_cli_tokens_path)
      expect(flash[:alert]).to eq("CLI token not found.")
      expect(admin_api_token.reload.revoked_at).to be_nil
    end
  end
end
