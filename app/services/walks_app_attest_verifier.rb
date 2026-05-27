# frozen_string_literal: true

require "cbor"

# Apple App Attest verification for the Gumroad Walks iOS app.
#
# Two entry points:
#
# - `attest(...)` is called once per install. It validates the one-time
#   attestation blob produced by `DCAppAttestService.attestKey`, persists the
#   attested EC P-256 public key as a `WalksAppAttestKey`, and returns the
#   record. The blob is CBOR-encoded {fmt, attStmt:{x5c, receipt}, authData}.
#
# - `assert(...)` is called on every walks API request. It validates the
#   per-request assertion blob produced by `DCAppAttestService.generateAssertion`,
#   verifies the assertion signature against the previously stored public key,
#   advances the StoreKit-style monotonic counter, and consumes the challenge.
#
# Apple's reference for both flows:
#   https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server
#
# Neither method ever raises on bad input — both return a `Result` whose
# `valid?` is false on failure and whose `error` is a stable symbol the caller
# can log.
class WalksAppAttestVerifier
  APPLE_ROOT_CA_PATH = Rails.root.join("config", "certs", "AppleAppAttestRootCA.pem")
  NONCE_OID = "1.2.840.113635.100.8.2"

  # The two AAGUIDs Apple uses for App Attest. Anything else means we're not
  # looking at a real Apple-issued attestation.
  AAGUID_PRODUCTION = "appattest\x00\x00\x00\x00\x00\x00\x00".b.freeze
  AAGUID_DEVELOPMENT = "appattestdevelop".b.freeze
  ENVIRONMENT_BY_AAGUID = {
    AAGUID_PRODUCTION => "production",
    AAGUID_DEVELOPMENT => "development",
  }.freeze

  BUNDLE_ID = "com.gumroad.walks"

  Result = Struct.new(:valid?, :key, :error, keyword_init: true)

  class << self
    def attest(key_id:, attestation_b64:, challenge:)
      return fail_result(:missing_key_id) if key_id.blank?
      return fail_result(:missing_attestation) if attestation_b64.blank?
      return fail_result(:invalid_challenge) unless WalksAppAttestChallenge.consume!(challenge)

      cbor = decode_cbor(Base64.decode64(attestation_b64))
      return fail_result(:bad_cbor) unless cbor.is_a?(Hash)
      return fail_result(:wrong_fmt) unless cbor["fmt"] == "apple-appattest"

      att_stmt = cbor["attStmt"]
      auth_data = cbor["authData"]
      return fail_result(:bad_att_stmt) unless att_stmt.is_a?(Hash)
      return fail_result(:bad_auth_data) unless auth_data.is_a?(String)

      # Validate x5c is an array of DER bytes before handing to OpenSSL — a
      # CBOR null inside the array would otherwise raise TypeError out of
      # OpenSSL::X509::Certificate.new(nil), which isn't in our rescue list.
      x5c = att_stmt["x5c"]
      return fail_result(:no_certs) unless x5c.is_a?(Array) && x5c.any?
      return fail_result(:no_certs) unless x5c.all? { |der| der.is_a?(String) && !der.empty? }
      certs = x5c.map { |der| OpenSSL::X509::Certificate.new(der) }
      return fail_result(:bad_chain) unless chain_valid?(certs.first, certs[1..])

      cred_cert = certs.first
      client_data_hash = OpenSSL::Digest::SHA256.digest(challenge.to_s)
      expected_nonce = OpenSSL::Digest::SHA256.digest(auth_data + client_data_hash)
      return fail_result(:nonce_mismatch) unless cert_nonce(cred_cert) == expected_nonce

      pub_key_bytes = ec_public_key_octets(cred_cert)
      credential_id = OpenSSL::Digest::SHA256.digest(pub_key_bytes)
      return fail_result(:key_id_mismatch) unless Base64.strict_decode64(key_id) == credential_id

      parsed = parse_auth_data(auth_data)
      return fail_result(:bad_auth_data) unless parsed

      return fail_result(:rp_id_mismatch) unless parsed[:rp_id_hash] == app_id_hash
      return fail_result(:bad_counter) unless parsed[:counter].zero?

      environment = ENVIRONMENT_BY_AAGUID[parsed[:aaguid]]
      return fail_result(:bad_aaguid) unless environment
      return fail_result(:wrong_env_for_rails) unless aaguid_allowed_in_env?(environment)
      return fail_result(:credential_id_mismatch) unless parsed[:credential_id] == credential_id

      key = WalksAppAttestKey.create!(
        key_id: key_id,
        public_key: cred_cert.public_key.to_der,
        environment: environment,
        attested_at: Time.current,
      )
      Result.new(valid?: true, key: key)
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      fail_result(:duplicate_key)
    rescue OpenSSL::X509::CertificateError, OpenSSL::PKey::PKeyError, ArgumentError => e
      Rails.logger.warn("WalksAppAttestVerifier.attest failed: #{e.class} #{e.message}")
      fail_result(:bad_cert)
    rescue CBOR::MalformedFormatError, EOFError => e
      Rails.logger.warn("WalksAppAttestVerifier.attest CBOR error: #{e.class} #{e.message}")
      fail_result(:bad_cbor)
    end

    def assert(key_id:, assertion_b64:, challenge:, request_body:)
      return fail_result(:missing_key_id) if key_id.blank?
      return fail_result(:missing_assertion) if assertion_b64.blank?
      return fail_result(:missing_challenge) if challenge.blank?

      key = WalksAppAttestKey.find_by(key_id: key_id)
      return fail_result(:unknown_key) unless key

      # Consume the challenge only after the keyId is known to be real.
      # A scraper hitting the endpoint with a random keyId would otherwise
      # be able to burn challenges issued to legitimate devices (single-use
      # Redis nonces). Since keyIds are SHA256(pubkey) — unguessable —
      # gating consume on `find_by` closes the DoS without changing the
      # replay-safety property: a real device's request still consumes
      # its own challenge exactly once.
      return fail_result(:invalid_challenge) unless WalksAppAttestChallenge.consume!(challenge)

      cbor = decode_cbor(Base64.decode64(assertion_b64))
      return fail_result(:bad_cbor) unless cbor.is_a?(Hash)

      signature = cbor["signature"]
      authenticator_data = cbor["authenticatorData"]
      return fail_result(:bad_assertion) unless signature.is_a?(String) && authenticator_data.is_a?(String)

      client_data_hash = OpenSSL::Digest::SHA256.digest(challenge.to_s + request_body.to_s)
      # Apple's App Attest assertion: the Secure Enclave is handed
      # `nonce = SHA256(authenticatorData || clientDataHash)` and signs it with
      # ES256, which hashes its input *again* with SHA256 before the ECDSA
      # operation. So the value actually signed is `SHA256(nonce)`. Apple's
      # CryptoKit reference, `publicKey.isValidSignature(sig, for: nonce)`,
      # passes `nonce` as a message (DataProtocol), so CryptoKit hashes it
      # before verifying — it does NOT treat `nonce` as a pre-computed digest.
      # `dsa_verify_asn1(digest, sig)` is a raw ECDSA verify with no hashing, so
      # we must pass `SHA256(nonce)`. Verifying against `nonce` directly is the
      # classic App Attest mistake and rejects every genuine assertion.
      nonce = OpenSSL::Digest::SHA256.digest(authenticator_data + client_data_hash)
      signed_digest = OpenSSL::Digest::SHA256.digest(nonce)
      return fail_result(:bad_signature) unless key.public_key_ec.dsa_verify_asn1(signed_digest, signature)

      parsed = parse_auth_data(authenticator_data, expect_attestation: false)
      return fail_result(:bad_auth_data) unless parsed
      return fail_result(:rp_id_mismatch) unless parsed[:rp_id_hash] == app_id_hash
      return fail_result(:counter_replay) unless key.advance_counter!(parsed[:counter])

      Result.new(valid?: true, key: key)
    rescue OpenSSL::PKey::PKeyError, ArgumentError => e
      Rails.logger.warn("WalksAppAttestVerifier.assert failed: #{e.class} #{e.message}")
      fail_result(:bad_signature)
    rescue CBOR::MalformedFormatError, EOFError => e
      Rails.logger.warn("WalksAppAttestVerifier.assert CBOR error: #{e.class} #{e.message}")
      fail_result(:bad_cbor)
    end

    private
      def fail_result(error)
        Result.new(valid?: false, key: nil, error: error)
      end

      def decode_cbor(bytes)
        CBOR.decode(bytes)
      end

      def chain_valid?(leaf, intermediates)
        store = OpenSSL::X509::Store.new
        store.add_cert(apple_root_ca)
        store.verify(leaf, intermediates)
      end

      def apple_root_ca
        @apple_root_ca ||= OpenSSL::X509::Certificate.new(File.read(APPLE_ROOT_CA_PATH))
      end

      # Apple embeds the attestation nonce as an OCTET STRING inside a
      # SEQUENCE inside a SEQUENCE inside the OID's extension value:
      #   ext.value (DER) → SEQUENCE { [0] EXPLICIT OCTET STRING (32 bytes) }
      def cert_nonce(cert)
        ext = cert.extensions.find { |e| e.oid == NONCE_OID }
        return nil unless ext
        outer = OpenSSL::ASN1.decode(ext.value_der)
        return nil unless outer.value.is_a?(Array)
        inner = outer.value.first
        return nil unless inner.respond_to?(:value)
        nested = inner.value
        nested = nested.first if nested.is_a?(Array)
        nested.respond_to?(:value) ? nested.value : nested
      end

      # Pull the uncompressed EC point (04 || X || Y, 65 bytes for P-256)
      # out of the cert's SubjectPublicKeyInfo.
      def ec_public_key_octets(cert)
        cert.public_key.public_key.to_octet_string(:uncompressed)
      end

      # Apple's authenticator data layout for App Attest:
      #   rpIdHash       (32)
      #   flags          (1)
      #   signCount      (4 BE)
      #   --- present only when AT flag set, i.e. attestation responses: ---
      #   aaguid         (16)
      #   credIdLen      (2 BE)
      #   credentialId   (credIdLen)
      #   credPubKey     (CBOR)  -- App Attest specifically does NOT include this;
      #                            the credentialId IS the SHA256(pubkey octets).
      def parse_auth_data(bytes, expect_attestation: true)
        return nil unless bytes.is_a?(String) && bytes.bytesize >= 37
        io = StringIO.new(bytes)
        io.binmode
        rp_id_hash = io.read(32)
        flags_byte = io.read(1)
        counter_bytes = io.read(4)
        return nil unless rp_id_hash && flags_byte && counter_bytes
        out = {
          rp_id_hash: rp_id_hash,
          flags: flags_byte.unpack1("C"),
          counter: counter_bytes.unpack1("N"),
        }
        if expect_attestation
          # Each io.read can return nil at EOF on a truncated blob; without
          # these guards `nil.unpack1` raises NoMethodError outside our
          # rescue list and surfaces as a 500 instead of a 422.
          aaguid = io.read(16)
          cred_id_len_bytes = io.read(2)
          return nil unless aaguid && aaguid.bytesize == 16 && cred_id_len_bytes && cred_id_len_bytes.bytesize == 2
          cred_id_len = cred_id_len_bytes.unpack1("n")
          return nil if cred_id_len > 64
          cred_id = io.read(cred_id_len)
          return nil unless cred_id && cred_id.bytesize == cred_id_len
          out[:aaguid] = aaguid
          out[:credential_id] = cred_id
        end
        out
      end

      def aaguid_allowed_in_env?(environment)
        Rails.env.production? ? environment == "production" : true
      end

      # rpId in App Attest is the App ID — `<teamId>.<bundleId>`. Reuses the
      # same APPLE_WEB_TEAM_ID env var that config/initializers/005_apple.rb
      # already reads for Sign in with Apple — the Team ID is the same value
      # regardless of which Apple service you're authenticating against.
      # Computed lazily so tests can stub it and so we don't bake a missing
      # env var into a frozen constant.
      def app_id_hash
        team_id = GlobalConfig.get("APPLE_WEB_TEAM_ID").to_s
        OpenSSL::Digest::SHA256.digest("#{team_id}.#{BUNDLE_ID}")
      end
  end
end
