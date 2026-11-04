# frozen_string_literal: true

require "spec_helper"

describe PingSignature do
  let(:secret) { "a" * 64 }
  let(:body) { "sale_id=abc&price=100" }
  let(:timestamp) { Time.utc(2026, 11, 4, 12, 0, 0) }

  describe ".sign" do
    it "signs the timestamp and the raw body with the seller's secret" do
      header = PingSignature.sign(secret:, body:, timestamp:)

      expect(header).to eq("t=#{timestamp.to_i},v1=#{PingSignature.digest(secret:, body:, timestamp: timestamp.to_i)}")
    end

    it "signs the body it was given, byte for byte" do
      expect(PingSignature.sign(secret:, body:, timestamp:)).not_to eq(PingSignature.sign(secret:, body: "#{body} ", timestamp:))
    end

    it "produces a lower-case hex digest" do
      expect(PingSignature.sign(secret:, body:, timestamp:)).to match(/\At=\d+,v1=[0-9a-f]{64}\z/)
    end
  end

  describe ".valid?" do
    let(:header) { PingSignature.sign(secret:, body:, timestamp:) }

    it "accepts a signature it produced for the same body and timestamp" do
      expect(PingSignature.valid?(secret:, body:, header:, now: timestamp)).to be(true)
    end

    it "rejects a body that changed after it was signed" do
      expect(PingSignature.valid?(secret:, body: "#{body}&extra=1", header:, now: timestamp)).to be(false)
    end

    it "rejects a signature made with another secret" do
      expect(PingSignature.valid?(secret: "b" * 64, body:, header:, now: timestamp)).to be(false)
    end

    it "rejects a timestamped signature replayed outside the tolerance window" do
      expect(PingSignature.valid?(secret:, body:, header:, now: timestamp + PingSignature::TOLERANCE + 1.second)).to be(false)
    end

    it "accepts a delivery whose clock is slightly ahead of the receiver's" do
      expect(PingSignature.valid?(secret:, body:, header:, now: timestamp - PingSignature::TOLERANCE + 1.second)).to be(true)
    end

    it "rejects a header without a version or a timestamp" do
      expect(PingSignature.valid?(secret:, body:, header: "", now: timestamp)).to be(false)
      expect(PingSignature.valid?(secret:, body:, header: "t=#{timestamp.to_i}", now: timestamp)).to be(false)
      expect(PingSignature.valid?(secret:, body:, header: "v1=deadbeef", now: timestamp)).to be(false)
      expect(PingSignature.valid?(secret:, body:, header: "t=not-a-number,v1=deadbeef", now: timestamp)).to be(false)
    end

    it "rejects anything when the seller has no secret" do
      expect(PingSignature.valid?(secret: nil, body:, header:, now: timestamp)).to be(false)
    end
  end
end
