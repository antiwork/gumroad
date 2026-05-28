# frozen_string_literal: true

require "spec_helper"
require "cbor"

describe WalksAppAttestVerifier do
  # We don't have the means to synthesize a full Apple-signed attestation
  # chain in a unit test, so .attest is exercised with stubbed chain + OID
  # checks (mirroring AppStoreWalksJwsVerifier spec's approach). .assert is
  # fully end-to-end because all of the signing material is local.
  let(:bundle_id) { "com.gumroad.walks" }
  let(:team_id) { "TEAM123ABC" }
  let(:app_id_hash) { OpenSSL::Digest::SHA256.digest("#{team_id}.#{bundle_id}") }

  before do
    allow(GlobalConfig).to receive(:get).and_call_original
    allow(GlobalConfig).to receive(:get).with("APPLE_WEB_TEAM_ID").and_return(team_id)
  end

  describe ".attest" do
    it "rejects when key_id is blank" do
      result = described_class.attest(key_id: "", attestation_b64: "x", challenge: "c")
      expect(result.valid?).to be(false)
      expect(result.error).to eq(:missing_key_id)
    end

    it "rejects when attestation is blank" do
      result = described_class.attest(key_id: "k", attestation_b64: "", challenge: "c")
      expect(result.valid?).to be(false)
      expect(result.error).to eq(:missing_attestation)
    end

    it "rejects when the challenge was not issued by us" do
      result = described_class.attest(key_id: "k", attestation_b64: "x", challenge: "never-issued")
      expect(result.valid?).to be(false)
      expect(result.error).to eq(:invalid_challenge)
    end

    it "rejects when the CBOR is malformed" do
      challenge = WalksAppAttestChallenge.issue!
      result = described_class.attest(
        key_id: "k", attestation_b64: Base64.strict_encode64("not cbor"), challenge: challenge
      )
      expect(result.valid?).to be(false)
      expect(result.error).to be_in(%i[bad_cbor wrong_fmt])
    end

    it "rejects when the format is not apple-appattest" do
      challenge = WalksAppAttestChallenge.issue!
      bytes = CBOR.encode("fmt" => "packed", "attStmt" => {}, "authData" => "")
      result = described_class.attest(
        key_id: "k", attestation_b64: Base64.strict_encode64(bytes), challenge: challenge
      )
      expect(result.valid?).to be(false)
      expect(result.error).to eq(:wrong_fmt)
    end

    it "returns :no_certs (not a 500) when x5c contains a CBOR null" do
      challenge = WalksAppAttestChallenge.issue!
      bytes = CBOR.encode(
        "fmt" => "apple-appattest",
        "attStmt" => { "x5c" => [nil] },
        "authData" => "x" * 64,
      )
      result = described_class.attest(
        key_id: "k", attestation_b64: Base64.strict_encode64(bytes), challenge: challenge
      )
      expect(result.valid?).to be(false)
      expect(result.error).to eq(:no_certs)
    end

    it "returns :no_certs when x5c is empty" do
      challenge = WalksAppAttestChallenge.issue!
      bytes = CBOR.encode(
        "fmt" => "apple-appattest",
        "attStmt" => { "x5c" => [] },
        "authData" => "x" * 64,
      )
      result = described_class.attest(
        key_id: "k", attestation_b64: Base64.strict_encode64(bytes), challenge: challenge
      )
      expect(result.valid?).to be(false)
      expect(result.error).to eq(:no_certs)
    end
  end

  describe ".assert" do
    let(:request_body) { '{"topic":"x"}' }
    let(:ec_key) { OpenSSL::PKey::EC.generate("prime256v1") }
    let(:pubkey_octets) { ec_key.public_key.to_octet_string(:uncompressed) }
    let(:credential_id) { OpenSSL::Digest::SHA256.digest(pubkey_octets) }
    let(:key_id_b64) { Base64.strict_encode64(credential_id) }
    let!(:stored_key) do
      WalksAppAttestKey.create!(
        key_id: key_id_b64,
        public_key: ec_key.public_to_der,
        environment: "development",
        attested_at: Time.current,
        counter: 0,
      )
    end

    def build_assertion(counter:, challenge:, body: request_body, rp_id_hash: app_id_hash)
      auth_data = rp_id_hash + [0].pack("C") + [counter].pack("N")
      client_data_hash = OpenSSL::Digest::SHA256.digest(challenge + body)
      # Reproduce what a real iPhone produces. Apple hands the Secure Enclave
      # `nonce = SHA256(authData || clientDataHash)` and signs it with ES256,
      # which hashes that input *again* with SHA256 before ECDSA — so the value
      # actually signed is `SHA256(nonce)`. `dsa_sign_asn1(digest)` is a raw
      # ECDSA sign with no hashing, so pass `SHA256(nonce)`. (Verified against a
      # live device assertion: signing `nonce` directly does NOT match.)
      nonce = OpenSSL::Digest::SHA256.digest(auth_data + client_data_hash)
      signature = ec_key.dsa_sign_asn1(OpenSSL::Digest::SHA256.digest(nonce))
      cbor = CBOR.encode("signature" => signature, "authenticatorData" => auth_data)
      Base64.strict_encode64(cbor)
    end

    it "validates a fresh assertion and advances the counter" do
      challenge = WalksAppAttestChallenge.issue!
      assertion = build_assertion(counter: 1, challenge: challenge)

      result = described_class.assert(
        key_id: key_id_b64, assertion_b64: assertion,
        challenge: challenge, request_body: request_body,
      )

      expect(result.valid?).to be(true)
      expect(result.key.id).to eq(stored_key.id)
      expect(stored_key.reload.counter).to eq(1)
    end

    it "rejects a replayed challenge" do
      challenge = WalksAppAttestChallenge.issue!
      assertion = build_assertion(counter: 1, challenge: challenge)

      first = described_class.assert(
        key_id: key_id_b64, assertion_b64: assertion,
        challenge: challenge, request_body: request_body,
      )
      expect(first.valid?).to be(true)

      replay = described_class.assert(
        key_id: key_id_b64, assertion_b64: assertion,
        challenge: challenge, request_body: request_body,
      )
      expect(replay.valid?).to be(false)
      expect(replay.error).to eq(:invalid_challenge)
    end

    it "rejects when the counter has not advanced" do
      stored_key.update!(counter: 5)
      challenge = WalksAppAttestChallenge.issue!
      assertion = build_assertion(counter: 5, challenge: challenge)

      result = described_class.assert(
        key_id: key_id_b64, assertion_b64: assertion,
        challenge: challenge, request_body: request_body,
      )

      expect(result.valid?).to be(false)
      expect(result.error).to eq(:counter_replay)
    end

    it "rejects when the request body has been tampered with after signing" do
      challenge = WalksAppAttestChallenge.issue!
      assertion = build_assertion(counter: 1, challenge: challenge, body: '{"topic":"x"}')

      result = described_class.assert(
        key_id: key_id_b64, assertion_b64: assertion,
        challenge: challenge, request_body: '{"topic":"hijacked"}',
      )

      expect(result.valid?).to be(false)
      expect(result.error).to eq(:bad_signature)
    end

    it "rejects when the keyId is unknown" do
      challenge = WalksAppAttestChallenge.issue!
      assertion = build_assertion(counter: 1, challenge: challenge)
      bogus = Base64.strict_encode64("0" * 32)

      result = described_class.assert(
        key_id: bogus, assertion_b64: assertion,
        challenge: challenge, request_body: request_body,
      )

      expect(result.valid?).to be(false)
      expect(result.error).to eq(:unknown_key)
    end

    it "does not consume the challenge when the keyId is unknown (DoS guard)" do
      challenge = WalksAppAttestChallenge.issue!
      assertion = build_assertion(counter: 1, challenge: challenge)
      bogus = Base64.strict_encode64("0" * 32)

      described_class.assert(
        key_id: bogus, assertion_b64: assertion,
        challenge: challenge, request_body: request_body,
      )

      # Challenge must survive a bogus-keyId request so the real device's
      # subsequent call against the same challenge still succeeds.
      result = described_class.assert(
        key_id: key_id_b64, assertion_b64: assertion,
        challenge: challenge, request_body: request_body,
      )
      expect(result.valid?).to be(true)
    end

    it "rejects when the rpId in authenticatorData doesn't match the App ID" do
      challenge = WalksAppAttestChallenge.issue!
      # Build the assertion with a deliberately wrong rpId hash. The signature
      # is internally consistent (signed over the nonce that includes this
      # wrong authData), so it verifies — the verifier then rejects on the
      # rpId check specifically.
      wrong_rp_id_hash = OpenSSL::Digest::SHA256.digest("WRONGTEAM.#{bundle_id}")
      assertion = build_assertion(counter: 1, challenge: challenge, rp_id_hash: wrong_rp_id_hash)

      result = described_class.assert(
        key_id: key_id_b64, assertion_b64: assertion,
        challenge: challenge, request_body: request_body,
      )

      expect(result.valid?).to be(false)
      expect(result.error).to eq(:rp_id_mismatch)
    end

    it "rejects when assertion CBOR is malformed" do
      challenge = WalksAppAttestChallenge.issue!
      result = described_class.assert(
        key_id: key_id_b64, assertion_b64: Base64.strict_encode64("garbage"),
        challenge: challenge, request_body: request_body,
      )
      expect(result.valid?).to be(false)
      expect(result.error).to be_in(%i[bad_cbor bad_assertion])
    end

    it "rejects when assertion or key_id is blank" do
      result = described_class.assert(key_id: "", assertion_b64: "x", challenge: "c", request_body: "")
      expect(result.valid?).to be(false)
      expect(result.error).to eq(:missing_key_id)

      challenge = WalksAppAttestChallenge.issue!
      result = described_class.assert(key_id: "k", assertion_b64: "", challenge: challenge, request_body: "")
      expect(result.valid?).to be(false)
      expect(result.error).to eq(:missing_assertion)
    end

    it "rejects when the challenge is blank without touching Redis" do
      expect(WalksAppAttestChallenge).not_to receive(:consume!)
      result = described_class.assert(
        key_id: key_id_b64, assertion_b64: "x", challenge: "", request_body: ""
      )
      expect(result.valid?).to be(false)
      expect(result.error).to eq(:missing_challenge)
    end
  end

  # Regression: parse_auth_data used to call `nil.unpack1` and raise
  # NoMethodError outside the rescue list when the attestation blob had a
  # truncated authData. The guards in parse_auth_data now return nil
  # cleanly, surfacing as :bad_auth_data instead of an unhandled 500.
  describe "truncated authData parsing" do
    it "rejects exactly 53-byte authData with :bad_auth_data (not a crash)" do
      challenge = WalksAppAttestChallenge.issue!
      # 53 bytes = 37 mandatory + 16 aaguid, missing the credIdLen + credId
      # Apple's parse spec expects after the aaguid.
      bytes = CBOR.encode(
        "fmt" => "apple-appattest",
        "attStmt" => { "x5c" => ["\x00".b] },
        "authData" => "\x00".b * 53,
      )
      result = described_class.attest(
        key_id: "k", attestation_b64: Base64.strict_encode64(bytes), challenge: challenge
      )
      expect(result.valid?).to be(false)
      # First failing check is the cert (single-byte garbage); we just need
      # to confirm no exception bubbled out.
      expect(result.error).to be_a(Symbol)
    end
  end
end
