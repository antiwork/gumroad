# frozen_string_literal: true

require "spec_helper"

describe WebauthnCredential do
  let(:user) { create(:user) }

  describe "validations" do
    it "requires a user" do
      credential = described_class.new

      expect(credential).not_to be_valid
      expect(credential.errors[:user]).to be_present
    end

    it "requires a unique webauthn_id" do
      existing_credential = create(:webauthn_credential, user:)
      duplicate = build(:webauthn_credential, user:, webauthn_id: existing_credential.webauthn_id)

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:webauthn_id]).to include("has already been taken")
    end

    it "allows credential IDs up to the WebAuthn maximum after base64url encoding" do
      credential = build(:webauthn_credential, user:, webauthn_id: "a" * described_class::MAX_WEBAUTHN_ID_LENGTH)

      expect(credential).to be_valid
    end

    it "rejects credential IDs longer than the WebAuthn maximum after base64url encoding" do
      credential = build(:webauthn_credential, user:, webauthn_id: "a" * (described_class::MAX_WEBAUTHN_ID_LENGTH + 1))

      expect(credential).not_to be_valid
      expect(credential.errors[:webauthn_id]).to include("is too long (maximum is #{described_class::MAX_WEBAUTHN_ID_LENGTH} characters)")
    end

    it "requires a public key" do
      credential = build(:webauthn_credential, user:, public_key: nil)

      expect(credential).not_to be_valid
      expect(credential.errors[:public_key]).to be_present
    end

    it "requires a non-negative sign count" do
      credential = build(:webauthn_credential, user:, sign_count: -1)

      expect(credential).not_to be_valid
      expect(credential.errors[:sign_count]).to include("must be greater than or equal to 0")
    end

    it "enforces the maximum passkey count per user" do
      create_list(:webauthn_credential, described_class::MAX_PER_USER, user:)

      credential = build(:webauthn_credential, user:)

      expect(credential).not_to be_valid
      expect(credential.errors[:base]).to include(described_class::MAX_PER_USER_ERROR_MESSAGE)
      expect(credential.errors.details[:base]).to include(error: described_class::MAX_PER_USER_ERROR)
    end

    it "allows existing passkeys to be renamed when the user is at the maximum" do
      credentials = create_list(:webauthn_credential, described_class::MAX_PER_USER, user:)

      credentials.first.nickname = "Security key"

      expect(credentials.first).to be_valid
    end
  end

  describe "default nickname" do
    it "uses the next passkey number when nickname is blank" do
      create(:webauthn_credential, user:)

      credential = create(:webauthn_credential, user:, nickname: " ")

      expect(credential.nickname).to eq("Passkey 2")
    end

    it "strips provided nicknames" do
      credential = create(:webauthn_credential, user:, nickname: "  MacBook Pro  ")

      expect(credential.nickname).to eq("MacBook Pro")
    end
  end
end
