# frozen_string_literal: true

require "spec_helper"

describe TotpCredential do
  let(:user) { create(:user) }

  describe "validations" do
    it "requires a user" do
      credential = TotpCredential.new
      expect(credential).not_to be_valid
      expect(credential.errors[:user]).to be_present
    end

    it "enforces uniqueness of user_id" do
      create(:totp_credential, user:)
      duplicate = build(:totp_credential, user:)
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:user_id]).to include("has already been taken")
    end
  end

  describe "otp_secret" do
    it "auto-generates otp_secret on create" do
      credential = create(:totp_credential, user:)
      expect(credential.otp_secret).to be_present
      expect(credential.otp_secret.length).to eq 32
    end
  end

  describe "#confirmed?" do
    it "returns false when confirmed_at is nil" do
      credential = create(:totp_credential, user:)
      expect(credential.confirmed?).to be false
    end

    it "returns true when confirmed_at is set" do
      credential = create(:totp_credential, :confirmed, user:)
      expect(credential.confirmed?).to be true
    end
  end

  describe "#verify_code" do
    let(:credential) { create(:totp_credential, :confirmed, user:) }

    it "returns true for a valid current TOTP code" do
      code = credential.otp_code
      expect(credential.verify_code(code)).to be true
    end

    it "returns false for an invalid code" do
      expect(credential.verify_code("000000")).to be false
    end

    it "accepts codes within 30-second drift" do
      code = nil
      travel_to(25.seconds.ago) { code = credential.otp_code }
      expect(credential.verify_code(code)).to be true
    end

    it "rejects codes beyond 30-second drift" do
      code = nil
      travel_to(65.seconds.ago) { code = credential.otp_code }
      expect(credential.verify_code(code)).to be false
    end
  end

  describe "#totp_provisioning_uri" do
    it "returns a valid otpauth URI" do
      credential = create(:totp_credential, user:)
      uri = credential.totp_provisioning_uri

      expect(uri).to start_with("otpauth://totp/")
      expect(uri).to include(ERB::Util.url_encode(user.email))
      expect(uri).to include("issuer=Gumroad")
      expect(uri).to include("secret=#{credential.otp_secret}")
    end
  end

  describe "#generate_recovery_codes" do
    let(:credential) { create(:totp_credential, :confirmed, user:) }

    it "returns 10 plaintext codes" do
      codes = credential.generate_recovery_codes
      expect(codes.length).to eq 10
      codes.each do |code|
        expect(code.length).to eq 8
        expect(code).to match(/\A[A-Z0-9]+\z/)
      end
    end

    it "stores bcrypt hashes in recovery_codes" do
      credential.generate_recovery_codes
      credential.reload

      expect(credential.recovery_codes).to be_an(Array)
      expect(credential.recovery_codes.length).to eq 10
      credential.recovery_codes.each do |h|
        expect { BCrypt::Password.new(h) }.not_to raise_error
      end
    end

    it "sets recovery_codes_generated_at" do
      freeze_time do
        credential.generate_recovery_codes
        expect(credential.recovery_codes_generated_at).to eq Time.current
      end
    end
  end

  describe "#redeem_recovery_code" do
    let(:credential) { create(:totp_credential, :confirmed, user:) }
    let!(:codes) { credential.generate_recovery_codes }

    it "returns true and removes a valid recovery code" do
      expect(credential.redeem_recovery_code(codes.first)).to be true
      expect(credential.reload.recovery_codes.size).to eq 9
    end

    it "is case-insensitive" do
      expect(credential.redeem_recovery_code(codes.first.downcase)).to be true
    end

    it "accepts codes with a dash" do
      code = codes.second
      expect(credential.redeem_recovery_code(code.insert(4, "-"))).to be true
    end

    it "returns false for an invalid code" do
      expect(credential.redeem_recovery_code("invalidcode")).to be false
    end

    it "prevents reuse of a redeemed code" do
      credential.redeem_recovery_code(codes.first)
      expect(credential.redeem_recovery_code(codes.first)).to be false
    end

    it "returns false when no recovery codes exist" do
      credential.update!(recovery_codes: nil)
      expect(credential.redeem_recovery_code("anything")).to be false
    end
  end
end
