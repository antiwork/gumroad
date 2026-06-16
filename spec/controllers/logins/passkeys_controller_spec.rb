# frozen_string_literal: true

require "spec_helper"
require "webauthn/fake_client"

describe Logins::PasskeysController, type: :controller do
  let(:user) { create(:user) }
  let(:origin) { "#{PROTOCOL}://#{DOMAIN}" }
  let(:rp_id) { WebAuthn.configuration.rp_id }
  let(:fake_client) { WebAuthn::FakeClient.new(origin) }

  before do
    request.env["devise.mapping"] = Devise.mappings[:user]
    Feature.activate(:passkeys)
  end

  def fake_register
    creation_challenge = WebAuthn::Credential.options_for_create(user: { id: user.external_id, name: user.email }).challenge
    created = fake_client.create(challenge: creation_challenge, rp_id:, user_verified: true)
    credential = WebAuthn::Credential.from_create(created)
    credential.verify(creation_challenge, user_verification: true)
    credential
  end

  def store_credential(credential)
    user.webauthn_credentials.create!(
      webauthn_id: credential.id,
      public_key: credential.public_key,
      sign_count: credential.sign_count,
      nickname: "Test passkey"
    )
  end

  def sign_in_with_passkey(challenge: nil, user_verified: true)
    post :options, as: :json
    assertion = fake_client.get(challenge: challenge || response.parsed_body.dig("options", "challenge"), rp_id:, user_verified:)
    post :create, params: { credential: assertion }, as: :json
  end

  describe "POST options" do
    it "returns assertion options for the discoverable flow and stores the challenge" do
      post :options, as: :json

      expect(response).to be_successful
      json = response.parsed_body
      expect(json["success"]).to be true
      expect(json["options"]["challenge"]).to be_present
      expect(json["options"]["allowCredentials"]).to eq([])
      expect(json["options"]["userVerification"]).to eq("required")
      expect(json["options"]["rpId"]).to eq(WebAuthn.configuration.rp_id)
      expect(session[Logins::PasskeysController::AUTHENTICATION_CHALLENGE_SESSION_KEY]).to eq(json["options"]["challenge"])
    end

    it "issues options even when a lingering signed-in session was invalidated elsewhere" do
      sign_in user
      user.update!(last_active_sessions_invalidated_at: 1.day.from_now)

      post :options, as: :json

      expect(response).to be_successful
      expect(response.parsed_body["success"]).to be true
      expect(response.parsed_body["options"]["challenge"]).to be_present
    end

    context "when the feature flag is inactive" do
      before { Feature.deactivate(:passkeys) }

      it "raises a not found error" do
        expect { post :options, as: :json }.to raise_error(ActionController::RoutingError, "Not Found")
      end
    end
  end

  describe "POST create" do
    it "signs the user in with a valid passkey assertion and bypasses the 2FA challenge" do
      credential = store_credential(fake_register)
      user.update!(two_factor_authentication_enabled: true)

      sign_in_with_passkey

      expect(response).to be_successful
      expect(response.parsed_body).to include("success" => true)
      expect(response.parsed_body["redirect_location"]).to be_present
      expect(controller.user_signed_in?).to be(true)
      expect(controller.current_user).to eq(user)
      expect(session[:verify_two_factor_auth_for]).to be_nil
      expect(credential.reload.last_used_at).to be_present
      expect(session.delete(Logins::PasskeysController::AUTHENTICATION_CHALLENGE_SESSION_KEY)).to be_nil
    end

    it "persists the updated sign count" do
      credential = store_credential(fake_register)

      sign_in_with_passkey

      expect(response).to be_successful
      expect(credential.reload.sign_count).to be > 0
    end

    it "clears a stale passkey setup prompt flag on sign-in" do
      store_credential(fake_register)
      session[:prompt_passkey_setup] = true

      sign_in_with_passkey

      expect(response).to be_successful
      expect(session[:prompt_passkey_setup]).to be_nil
    end

    it "merges the guest cart with the user's cart" do
      store_credential(fake_register)

      expect_any_instance_of(described_class).to receive(:merge_guest_cart_with_user_cart)

      sign_in_with_passkey

      expect(response).to be_successful
    end

    it "rejects an assertion for a credential that is not stored" do
      fake_register # registered with the authenticator but never persisted

      sign_in_with_passkey

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["success"]).to be false
      expect(controller.user_signed_in?).to be(false)
    end

    it "rejects an assertion signed against a stale challenge" do
      store_credential(fake_register)

      sign_in_with_passkey(challenge: WebAuthn::Credential.options_for_get.challenge)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(controller.user_signed_in?).to be(false)
    end

    it "does not sign in a deleted user" do
      store_credential(fake_register)
      user.mark_deleted!

      sign_in_with_passkey

      expect(response).to have_http_status(:unprocessable_entity)
      expect(controller.user_signed_in?).to be(false)
    end

    it "returns a generic error when there is no stored challenge" do
      store_credential(fake_register)
      assertion = fake_client.get(rp_id:, user_verified: true)

      post :create, params: { credential: assertion }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["success"]).to be false
      expect(controller.user_signed_in?).to be(false)
    end

    it "returns a generic error for a malformed assertion instead of a server error" do
      post :options, as: :json

      post :create, params: { credential: { id: "AAA", type: "public-key", response: {} } }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["success"]).to be false
      expect(controller.user_signed_in?).to be(false)
    end

    it "ignores an unrequested appid extension instead of returning a server error" do
      store_credential(fake_register)

      post :options, as: :json
      assertion = fake_client.get(challenge: response.parsed_body.dig("options", "challenge"), rp_id:, user_verified: true)
      assertion["clientExtensionResults"] = { "appid" => true }

      post :create, params: { credential: assertion }, as: :json

      expect(response).to be_successful
      expect(response.parsed_body).to include("success" => true)
      expect(controller.user_signed_in?).to be(true)
    end

    context "when the feature flag is inactive" do
      before { Feature.deactivate(:passkeys) }

      it "raises a not found error" do
        expect { post :create, params: { credential: {} }, as: :json }.to raise_error(ActionController::RoutingError, "Not Found")
      end
    end
  end
end
