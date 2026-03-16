# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe Settings::TotpController, type: :controller do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:user) { create(:user) }

  before do
    sign_in user
  end

  it_behaves_like "authorize called for controller", Settings::Totp::UserPolicy do
    let(:record) { user }
  end

  describe "POST create" do
    it "creates a totp credential and returns setup data" do
      post :create

      expect(response).to be_successful
      json = response.parsed_body
      expect(json["success"]).to be true
      expect(json["secret"]).to be_present
      expect(json["provisioning_uri"]).to start_with("otpauth://totp/")
      expect(json["provisioning_uri"]).to include("issuer=Gumroad")
      expect(json["qr_svg"]).to include("<svg")
      expect(user.reload.totp_credential).to be_present
      expect(user.totp_credential).not_to be_confirmed
    end

    context "when user already has a confirmed totp credential" do
      before do
        create(:totp_credential, :confirmed, user:)
      end

      it "returns an error" do
        post :create

        expect(response).to have_http_status(:unprocessable_entity)
        json = response.parsed_body
        expect(json["success"]).to be false
        expect(json["error_message"]).to eq("Authenticator app is already enabled.")
      end
    end

    context "when user has an unconfirmed totp credential from a previous attempt" do
      before do
        create(:totp_credential, user:)
      end

      it "destroys the old credential and creates a new one" do
        old_credential_id = user.totp_credential.id

        post :create

        expect(response).to be_successful
        expect(user.reload.totp_credential.id).not_to eq(old_credential_id)
      end
    end
  end

  describe "POST confirm" do
    context "when user has an unconfirmed totp credential" do
      let!(:credential) { create(:totp_credential, user:) }

      it "confirms the credential with a valid code and returns formatted recovery codes" do
        code = credential.otp_code

        post :confirm, params: { code: }

        expect(response).to be_successful
        json = response.parsed_body
        expect(json["success"]).to be true
        expect(json["recovery_codes"]).to be_an(Array)
        expect(json["recovery_codes"].length).to eq(10)
        json["recovery_codes"].each { |c| expect(c).to match(/\A[A-Z0-9]{4}-[A-Z0-9]{4}\z/) }
        expect(credential.reload).to be_confirmed
      end

      it "returns an error with an invalid code" do
        post :confirm, params: { code: "000000" }

        expect(response).to have_http_status(:unprocessable_entity)
        json = response.parsed_body
        expect(json["success"]).to be false
        expect(json["error_message"]).to eq("Invalid code. Please try again.")
        expect(credential.reload).not_to be_confirmed
      end
    end

    context "when user has no totp credential" do
      it "returns an error" do
        post :confirm, params: { code: "123456" }

        expect(response).to have_http_status(:unprocessable_entity)
        json = response.parsed_body
        expect(json["error_message"]).to eq("No pending TOTP setup found.")
      end
    end

    context "when user has an already confirmed totp credential" do
      before do
        create(:totp_credential, :confirmed, user:)
      end

      it "returns an error" do
        post :confirm, params: { code: "123456" }

        expect(response).to have_http_status(:unprocessable_entity)
        json = response.parsed_body
        expect(json["error_message"]).to eq("No pending TOTP setup found.")
      end
    end
  end

  describe "DELETE destroy" do
    context "when user has a confirmed totp credential" do
      before do
        create(:totp_credential, :confirmed, user:)
      end

      it "destroys the totp credential" do
        delete :destroy

        expect(response).to be_successful
        json = response.parsed_body
        expect(json["success"]).to be true
        expect(user.reload.totp_credential).to be_nil
      end
    end

    context "when user does not have totp enabled" do
      it "returns an error" do
        delete :destroy

        expect(response).to have_http_status(:unprocessable_entity)
        json = response.parsed_body
        expect(json["error_message"]).to eq("Authenticator app is not enabled.")
      end
    end
  end

  describe "POST regenerate_recovery_codes" do
    context "when user has a confirmed totp credential" do
      let!(:credential) { create(:totp_credential, :with_recovery_codes, user:) }

      it "regenerates formatted recovery codes" do
        old_codes = credential.recovery_codes

        post :regenerate_recovery_codes

        expect(response).to be_successful
        json = response.parsed_body
        expect(json["success"]).to be true
        expect(json["recovery_codes"]).to be_an(Array)
        expect(json["recovery_codes"].length).to eq(10)
        json["recovery_codes"].each { |c| expect(c).to match(/\A[A-Z0-9]{4}-[A-Z0-9]{4}\z/) }
        expect(credential.reload.recovery_codes).not_to eq(old_codes)
      end
    end

    context "when user does not have totp enabled" do
      it "returns an error" do
        post :regenerate_recovery_codes

        expect(response).to have_http_status(:unprocessable_entity)
        json = response.parsed_body
        expect(json["error_message"]).to eq("Authenticator app is not enabled.")
      end
    end
  end
end
