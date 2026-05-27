# frozen_string_literal: true

require "spec_helper"

describe WalksAppAttestChallenge do
  describe ".issue!" do
    it "issues a 32+ char url-safe string and writes it to redis with a TTL" do
      challenge = described_class.issue!
      expect(challenge).to match(/\A[A-Za-z0-9_-]{30,}\z/)
      key = RedisKey.walks_app_attest_challenge(challenge)
      expect($redis.get(key)).to eq("1")
      expect($redis.ttl(key)).to be_within(5).of(described_class::TTL.to_i)
    end

    it "produces a distinct challenge on each call" do
      a = described_class.issue!
      b = described_class.issue!
      expect(a).not_to eq(b)
    end
  end

  describe ".consume!" do
    it "deletes the challenge and returns true the first time" do
      challenge = described_class.issue!
      expect(described_class.consume!(challenge)).to be(true)
      expect($redis.get(RedisKey.walks_app_attest_challenge(challenge))).to be_nil
    end

    it "returns false on second consume" do
      challenge = described_class.issue!
      described_class.consume!(challenge)
      expect(described_class.consume!(challenge)).to be(false)
    end

    it "returns false for an unknown challenge" do
      expect(described_class.consume!("never-issued")).to be(false)
    end

    it "returns false for blank input" do
      expect(described_class.consume!("")).to be(false)
      expect(described_class.consume!(nil)).to be(false)
    end
  end
end
