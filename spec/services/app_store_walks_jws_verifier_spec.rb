# frozen_string_literal: true

require "spec_helper"

describe AppStoreWalksJwsVerifier do
  # Generating real Apple-chain-anchored test fixtures is out of scope; the
  # service rejects everything that isn't anchored at Apple Root CA G3.
  # These tests cover the cheap-rejection edge cases without needing real
  # signatures, plus the happy-path branches via stubbing the chain check.

  describe ".verify" do
    it "rejects an empty input" do
      result = described_class.verify("")
      expect(result.valid?).to be(false)
      expect(result.error).to eq("missing")
    end

    it "rejects a nil input" do
      result = described_class.verify(nil)
      expect(result.valid?).to be(false)
      expect(result.error).to eq("missing")
    end

    it "rejects a malformed JWS string" do
      result = described_class.verify("not-a-jws")
      expect(result.valid?).to be(false)
      expect(result.error).to eq("malformed")
    end

    it "rejects a JWS whose header decodes to JSON null (was 500 before guard)" do
      header = Base64.urlsafe_encode64("null", padding: false)
      jws = [header, "payload", "signature"].join(".")
      result = described_class.verify(jws)
      expect(result.valid?).to be(false)
      expect(result.error).to eq("malformed")
    end

    it "rejects a JWS whose header decodes to a JSON array" do
      header = Base64.urlsafe_encode64("[]", padding: false)
      jws = [header, "payload", "signature"].join(".")
      result = described_class.verify(jws)
      expect(result.valid?).to be(false)
      expect(result.error).to eq("malformed")
    end

    it "rejects a JWS whose header decodes to a JSON number" do
      header = Base64.urlsafe_encode64("123", padding: false)
      jws = [header, "payload", "signature"].join(".")
      result = described_class.verify(jws)
      expect(result.valid?).to be(false)
      expect(result.error).to eq("malformed")
    end

    it "rejects a JWS whose header has no x5c chain" do
      header = Base64.urlsafe_encode64({ alg: "ES256" }.to_json, padding: false)
      jws = [header, "payload", "signature"].join(".")
      result = described_class.verify(jws)
      expect(result.valid?).to be(false)
      expect(result.error).to eq("no_x5c")
    end

    it "rejects a JWS whose x5c contains a null element (was 500 before guard)" do
      header = Base64.urlsafe_encode64({ alg: "ES256", x5c: [nil, "abc"] }.to_json, padding: false)
      jws = [header, "payload", "signature"].join(".")
      result = described_class.verify(jws)
      expect(result.valid?).to be(false)
      expect(result.error).to eq("no_x5c")
    end

    it "rejects a JWS whose x5c contains a non-string element" do
      header = Base64.urlsafe_encode64({ alg: "ES256", x5c: [123, "abc"] }.to_json, padding: false)
      jws = [header, "payload", "signature"].join(".")
      result = described_class.verify(jws)
      expect(result.valid?).to be(false)
      expect(result.error).to eq("no_x5c")
    end

    it "rejects a JWS whose x5c contains an empty string" do
      header = Base64.urlsafe_encode64({ alg: "ES256", x5c: ["", "abc"] }.to_json, padding: false)
      jws = [header, "payload", "signature"].join(".")
      result = described_class.verify(jws)
      expect(result.valid?).to be(false)
      expect(result.error).to eq("no_x5c")
    end

    context "with a JWS whose cert chain doesn't anchor at Apple's root" do
      it "rejects with chain error" do
        # Synthesize an x5c chain from a self-signed cert. Apple Root CA G3
        # is bundled but our self-signed leaf won't verify against it.
        key = OpenSSL::PKey::EC.generate("prime256v1")
        cert = OpenSSL::X509::Certificate.new
        cert.version = 2
        cert.serial = 1
        cert.subject = OpenSSL::X509::Name.parse("/CN=test")
        cert.issuer = cert.subject
        cert.public_key = OpenSSL::PKey::EC.new(key).tap { |k| k.private_key = nil }
        cert.not_before = Time.now - 60
        cert.not_after = Time.now + 3600
        cert.sign(key, OpenSSL::Digest.new("SHA256"))
        x5c = [Base64.strict_encode64(cert.to_der), Base64.strict_encode64(cert.to_der)]
        header = Base64.urlsafe_encode64({ alg: "ES256", x5c: x5c }.to_json, padding: false)
        payload = Base64.urlsafe_encode64({ productId: "ProSub" }.to_json, padding: false)
        # Don't even bother with a real signature — chain check fails first.
        jws = [header, payload, "sig"].join(".")
        result = described_class.verify(jws)
        expect(result.valid?).to be(false)
        expect(result.error).to eq("chain")
      end
    end

    context "happy path (chain check stubbed)" do
      let(:key) { OpenSSL::PKey::EC.generate("prime256v1") }
      let(:cert) do
        OpenSSL::X509::Certificate.new.tap do |c|
          c.version = 2
          c.serial = 1
          c.subject = OpenSSL::X509::Name.parse("/CN=test-leaf")
          c.issuer = c.subject
          c.public_key = OpenSSL::PKey::EC.new(key).tap { |k| k.private_key = nil }
          c.not_before = Time.now - 60
          c.not_after = Time.now + 3600
          c.sign(key, OpenSSL::Digest.new("SHA256"))
        end
      end

      before do
        allow_any_instance_of(OpenSSL::X509::Store).to receive(:verify).and_return(true)
      end

      def make_jws(payload_attrs)
        x5c = [Base64.strict_encode64(cert.to_der), Base64.strict_encode64(cert.to_der)]
        header = { alg: "ES256", x5c: x5c }
        JWT.encode(payload_attrs, key, "ES256", header)
      end

      it "returns valid?: true for a current ProSub subscription" do
        result = described_class.verify(make_jws({
          productId: "ProSub",
          bundleId: "com.gumroad.walks",
          environment: "Sandbox",
          expiresDate: (Time.current.to_i + 86_400) * 1000,
          originalTransactionId: "1000000123",
        }))
        expect(result.valid?).to be(true)
        expect(result.product_id).to eq("ProSub")
        expect(result.original_transaction_id).to eq("1000000123")
      end

      it "rejects an expired subscription" do
        result = described_class.verify(make_jws({
          productId: "ProSub",
          bundleId: "com.gumroad.walks",
          environment: "Sandbox",
          expiresDate: (Time.current.to_i - 86_400) * 1000,
        }))
        expect(result.valid?).to be(false)
        expect(result.error).to eq("not_entitled")
      end

      it "rejects a revoked subscription" do
        result = described_class.verify(make_jws({
          productId: "ProSub",
          bundleId: "com.gumroad.walks",
          environment: "Sandbox",
          expiresDate: (Time.current.to_i + 86_400) * 1000,
          revocationDate: (Time.current.to_i - 60) * 1000,
        }))
        expect(result.valid?).to be(false)
      end

      it "rejects a subscription for a different product id" do
        result = described_class.verify(make_jws({
          productId: "OtherSub",
          bundleId: "com.gumroad.walks",
          environment: "Sandbox",
          expiresDate: (Time.current.to_i + 86_400) * 1000,
        }))
        expect(result.valid?).to be(false)
      end

      it "rejects a subscription from the wrong bundle" do
        result = described_class.verify(make_jws({
          productId: "ProSub",
          bundleId: "com.other.app",
          environment: "Sandbox",
          expiresDate: (Time.current.to_i + 86_400) * 1000,
        }))
        expect(result.valid?).to be(false)
      end

      it "rejects a subscription from the wrong environment" do
        result = described_class.verify(make_jws({
          productId: "ProSub",
          bundleId: "com.gumroad.walks",
          environment: "Production",
          expiresDate: (Time.current.to_i + 86_400) * 1000,
        }))
        expect(result.valid?).to be(false)
      end
    end
  end
end
