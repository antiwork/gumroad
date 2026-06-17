# frozen_string_literal: true

require "spec_helper"
require "webauthn/fake_client"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe Settings::PasskeysController, type: :controller do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:user) { create(:user) }
  let(:origin) { "#{PROTOCOL}://#{DOMAIN}" }
  let(:rp_id) { WebAuthn.configuration.rp_id }

  before do
    sign_in user
    Feature.activate_user(:passkeys, user)
  end

  it_behaves_like "authorize called for controller", Settings::Passkeys::UserPolicy do
    let(:record) { user }
    let(:request_params) { { id: create(:webauthn_credential, user:).external_id } }
  end

  describe "POST registration_options" do
    it "returns passkey registration options and stores the challenge in the session" do
      post :registration_options, as: :json

      expect(response).to be_successful
      json = response.parsed_body
      options = json["options"]
      expect(json["success"]).to be true
      expect(options["challenge"]).to be_present
      expect(options["rp"]).to include("id" => rp_id, "name" => "Gumroad")
      expect(options["user"]).to include("id" => user.external_id, "name" => user.email)
      expect(options["authenticatorSelection"]).to include("residentKey" => "required", "userVerification" => "required")
      expect(options["attestation"]).to eq("none")
      expect(session[Settings::PasskeysController::REGISTRATION_CHALLENGE_SESSION_KEY]).to eq(options["challenge"])
    end

    it "excludes the user's existing passkeys" do
      credential = create(:webauthn_credential, user:)

      post :registration_options, as: :json

      options = response.parsed_body["options"]
      expect(options["excludeCredentials"]).to contain_exactly("type" => "public-key", "id" => credential.webauthn_id)
    end

    it "returns an error when the user already has the maximum number of passkeys" do
      create_list(:webauthn_credential, WebauthnCredential::MAX_PER_USER, user:)

      post :registration_options, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq(
        "success" => false,
        "error_message" => WebauthnCredential::MAX_PER_USER_ERROR_MESSAGE
      )
    end

    context "when the feature flag is inactive" do
      before { Feature.deactivate_user(:passkeys, user) }

      it "raises a not found error" do
        expect { post :registration_options, as: :json }.to raise_error(ActionController::RoutingError, "Not Found")
      end
    end

    context "when signed in as an admin for the seller" do
      let(:seller) { user }

      include_context "with user signed in as admin for seller"

      it "returns unauthorized" do
        post :registration_options, as: :json

        expect(response).to have_http_status(:unauthorized)
        expect(response.parsed_body["success"]).to be false
      end
    end
  end

  describe "POST create" do
    it "verifies the WebAuthn attestation and stores the passkey" do
      post :registration_options, as: :json
      credential_params = fake_client.create(
        challenge: response.parsed_body.dig("options", "challenge"),
        rp_id:,
        user_verified: true
      )

      post :create, params: { credential: credential_params, nickname: "MacBook Pro" }, as: :json

      expect(response).to have_http_status(:created)
      json = response.parsed_body
      credential = user.reload.webauthn_credentials.sole
      expect(json["success"]).to be true
      expect(json["passkey"]).to include(
        "id" => credential.external_id,
        "nickname" => "MacBook Pro"
      )
      expect(credential.webauthn_id).to eq(credential_params["id"])
      expect(credential.public_key).to be_present
      expect(credential.sign_count).to eq(0)
      expect(session[Settings::PasskeysController::REGISTRATION_CHALLENGE_SESSION_KEY]).to be_nil
    end

    it "clears the setup prompt flag once a passkey is added" do
      session[:prompt_passkey_setup] = true
      post :registration_options, as: :json
      credential_params = fake_client.create(
        challenge: response.parsed_body.dig("options", "challenge"),
        rp_id:,
        user_verified: true
      )

      post :create, params: { credential: credential_params }, as: :json

      expect(response).to have_http_status(:created)
      expect(session[:prompt_passkey_setup]).to be_nil
    end

    it "ignores unexpected credential payload fields before verification" do
      post :registration_options, as: :json
      credential_params = valid_credential_params.merge("unexpected" => "ignored")
      credential_params["response"] = credential_params["response"].merge("unexpected" => "ignored")

      allow(WebAuthn::Credential).to receive(:from_create).and_wrap_original do |method, credential|
        expect(credential).not_to have_key("unexpected")
        expect(credential["response"]).not_to have_key("unexpected")

        method.call(credential)
      end

      post :create, params: { credential: credential_params }, as: :json

      expect(response).to have_http_status(:created)
    end

    it "uses a default nickname when none is provided" do
      post :registration_options, as: :json

      post :create, params: { credential: valid_credential_params }, as: :json

      expect(response).to have_http_status(:created)
      expect(user.reload.webauthn_credentials.sole.nickname).to eq("Passkey 1")
    end

    it "names the passkey after the detected provider when no nickname is provided" do
      expect(WebauthnCredential).to receive(:provider_name_for_aaguid).with(a_string_matching(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)).and_return("1Password")

      post :registration_options, as: :json

      post :create, params: { credential: valid_credential_params }, as: :json

      expect(response).to have_http_status(:created)
      expect(user.reload.webauthn_credentials.sole.nickname).to eq("1Password")
    end

    it "rejects a stale challenge" do
      post :registration_options, as: :json
      credential_params = fake_client.create(
        challenge: WebAuthn::Credential.options_for_create(user: { id: "other-user", name: "other@example.com" }).challenge,
        rp_id:,
        user_verified: true
      )

      post :create, params: { credential: credential_params }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq(
        "success" => false,
        "error_message" => Settings::PasskeysController::REGISTRATION_ERROR_MESSAGE
      )
      expect(user.reload.webauthn_credentials).to be_empty
      expect(session[Settings::PasskeysController::REGISTRATION_CHALLENGE_SESSION_KEY]).to be_nil
    end

    it "rejects a credential from the wrong origin" do
      post :registration_options, as: :json
      credential_params = WebAuthn::FakeClient.new("http://evil.example.com").create(
        challenge: response.parsed_body.dig("options", "challenge"),
        rp_id:,
        user_verified: true
      )

      post :create, params: { credential: credential_params }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(user.reload.webauthn_credentials).to be_empty
    end

    it "rejects a credential without user verification" do
      post :registration_options, as: :json
      credential_params = fake_client.create(
        challenge: response.parsed_body.dig("options", "challenge"),
        rp_id:,
        user_verified: false
      )

      post :create, params: { credential: credential_params }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(user.reload.webauthn_credentials).to be_empty
    end

    it "returns a generic error when no registration challenge exists" do
      post :create, params: { credential: fake_client.create(rp_id:, user_verified: true) }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error_message"]).to eq(Settings::PasskeysController::REGISTRATION_ERROR_MESSAGE)
    end

    it "returns a generic error for malformed credential payloads" do
      post :registration_options, as: :json

      post :create, params: { credential: { type: "public-key", id: "not-base64url", response: {} } }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq(
        "success" => false,
        "error_message" => Settings::PasskeysController::REGISTRATION_ERROR_MESSAGE
      )
      expect(user.reload.webauthn_credentials).to be_empty
      expect(session[Settings::PasskeysController::REGISTRATION_CHALLENGE_SESSION_KEY]).to be_nil
    end

    it "returns a generic error for scalar credential payloads" do
      post :registration_options, as: :json

      post :create, params: { credential: "not-a-credential" }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq(
        "success" => false,
        "error_message" => Settings::PasskeysController::REGISTRATION_ERROR_MESSAGE
      )
      expect(user.reload.webauthn_credentials).to be_empty
    end

    it "returns a generic error for invalid base64url credential strings" do
      post :registration_options, as: :json

      post :create, params: {
        credential: {
          type: "public-key",
          id: "***",
          rawId: "***",
          response: {
            attestationObject: "***",
            clientDataJSON: "***"
          }
        }
      }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq(
        "success" => false,
        "error_message" => Settings::PasskeysController::REGISTRATION_ERROR_MESSAGE
      )
      expect(user.reload.webauthn_credentials).to be_empty
    end

    it "returns a generic error for structurally invalid attestation objects" do
      post :registration_options, as: :json
      encoded_client_data = Base64.urlsafe_encode64({
        type: "webauthn.create",
        challenge: response.parsed_body.dig("options", "challenge"),
        origin:
      }.to_json, padding: false)

      post :create, params: {
        credential: {
          type: "public-key",
          id: "AA",
          rawId: "AA",
          response: {
            attestationObject: "AA",
            clientDataJSON: encoded_client_data
          }
        }
      }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq(
        "success" => false,
        "error_message" => Settings::PasskeysController::REGISTRATION_ERROR_MESSAGE
      )
      expect(user.reload.webauthn_credentials).to be_empty
    end

    it "returns the max-passkeys error when the limit is reached after options were issued" do
      create_list(:webauthn_credential, WebauthnCredential::MAX_PER_USER - 1, user:)
      post :registration_options, as: :json
      credential_params = valid_credential_params
      create(:webauthn_credential, user:)

      post :create, params: { credential: credential_params }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq(
        "success" => false,
        "error_message" => WebauthnCredential::MAX_PER_USER_ERROR_MESSAGE
      )
      expect(user.reload.webauthn_credentials.count).to eq(WebauthnCredential::MAX_PER_USER)
    end
  end

  describe "PATCH update" do
    let!(:credential) { create(:webauthn_credential, user:, nickname: "Old name") }

    it "renames the passkey" do
      patch :update, params: { id: credential.external_id, nickname: "  Security key  " }, as: :json

      expect(response).to be_successful
      expect(response.parsed_body["passkey"]["nickname"]).to eq("Security key")
      expect(credential.reload.nickname).to eq("Security key")
    end

    it "returns an error for a blank nickname" do
      patch :update, params: { id: credential.external_id, nickname: " " }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["success"]).to be false
      expect(credential.reload.nickname).to eq("Old name")
    end
  end

  describe "DELETE destroy" do
    let!(:credential) { create(:webauthn_credential, user:) }

    it "deletes the passkey" do
      delete :destroy, params: { id: credential.external_id }, as: :json

      expect(response).to be_successful
      expect(response.parsed_body["success"]).to be true
      expect(user.reload.webauthn_credentials).to be_empty
    end
  end

  def fake_client
    WebAuthn::FakeClient.new(origin)
  end

  def valid_credential_params
    fake_client.create(
      challenge: response.parsed_body.dig("options", "challenge"),
      rp_id:,
      user_verified: true
    )
  end
end
