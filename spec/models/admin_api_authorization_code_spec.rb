# frozen_string_literal: true

require "spec_helper"

describe AdminApiAuthorizationCode do
  describe ".code_challenge_for" do
    it "uses S256 raw URL-safe base64 to match the Gumroad CLI" do
      code_verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"

      expect(described_class.code_challenge_for(code_verifier)).to eq("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    end
  end

  describe ".create_for!" do
    it "stores a hashed code with a 60 second expiry" do
      actor = create(:admin_user)
      code_challenge = described_class.code_challenge_for("verifier")

      freeze_time do
        plaintext_code = described_class.create_for!(actor_user: actor, code_challenge:)
        authorization_code = described_class.find_by!(code_hash: described_class.hash_code(plaintext_code))

        expect(authorization_code).to have_attributes(
          actor_user: actor,
          code_challenge:,
          expires_at: 60.seconds.from_now
        )
      end
    end
  end

  describe ".exchange!" do
    it "mints an admin token and marks the code used when the PKCE verifier matches" do
      actor = create(:admin_user)
      plaintext_code = "authorization-code"
      code_verifier = "code-verifier"
      authorization_code = create(:admin_api_authorization_code, actor_user: actor, plaintext_code:, code_verifier:)

      plaintext_token, admin_api_token = described_class.exchange!(code: plaintext_code, code_verifier:)

      expect(admin_api_token).to have_attributes(
        actor_user: actor,
        expires_at: be_present
      )
      expect(AdminApiToken.authenticate(plaintext_token)).to eq(admin_api_token)
      expect(authorization_code.reload).to have_attributes(used_at: be_present, admin_api_token:)
    end

    it "rejects mismatched, expired, and already-used codes" do
      mismatched_code = create(:admin_api_authorization_code, plaintext_code: "mismatched-code", code_verifier: "expected")
      expired_code = create(:admin_api_authorization_code, plaintext_code: "expired-code", expires_at: 1.second.ago)
      used_code = create(:admin_api_authorization_code, plaintext_code: "used-code", used_at: Time.current)

      expect(described_class.exchange!(code: "mismatched-code", code_verifier: "wrong")).to be_nil
      expect(described_class.exchange!(code: "expired-code", code_verifier: "test-code-verifier")).to be_nil
      expect(described_class.exchange!(code: "used-code", code_verifier: "test-code-verifier")).to be_nil
      expect(mismatched_code.reload.admin_api_token).to be_nil
      expect(expired_code.reload.admin_api_token).to be_nil
      expect(used_code.reload.admin_api_token).to be_nil
    end
  end
end
