# frozen_string_literal: true

require "spec_helper"

describe GmailAbuseFilter do
  after { $redis.del(described_class::REDIS_KEY) }

  describe ".exists?" do
    before { described_class.add!("abuser@gmail.com") }

    it "returns true for a matching normalized email" do
      expect(described_class.exists?("abuser@gmail.com")).to be(true)
    end

    it "returns true for plus-addressed variants" do
      expect(described_class.exists?("abuser+spam@gmail.com")).to be(true)
    end

    it "returns true for dot variants" do
      expect(described_class.exists?("a.b.u.s.e.r@gmail.com")).to be(true)
    end

    it "returns false for non-matching email" do
      expect(described_class.exists?("innocent@gmail.com")).to be(false)
    end

    it "returns false for non-Gmail addresses" do
      expect(described_class.exists?("abuser@example.com")).to be(false)
    end
  end

  describe ".add!" do
    it "adds the normalized email to the Redis set" do
      described_class.add!("a.b.u.s.e.r+test@gmail.com")

      expect($redis.sismember(described_class::REDIS_KEY, "abuser@gmail.com")).to be(true)
    end

    it "ignores non-Gmail addresses" do
      described_class.add!("user@example.com")

      expect($redis.scard(described_class::REDIS_KEY)).to eq(0)
    end
  end

  describe ".remove!" do
    before { described_class.add!("abuser@gmail.com") }

    it "removes the normalized email from the Redis set" do
      described_class.remove!("abuser+old@gmail.com")

      expect(described_class.exists?("abuser@gmail.com")).to be(false)
    end
  end

  describe ".rebuild!" do
    before do
      create(:user, user_risk_state: "suspended_for_fraud", email: "fraud+one@gmail.com")
      create(:user, user_risk_state: "suspended_for_tos_violation", email: "tos.violator@gmail.com")
      create(:user, user_risk_state: "flagged_for_fraud", email: "flagged@gmail.com")
      create(:compliant_user, email: "good@gmail.com")
      create(:user, user_risk_state: "suspended_for_fraud", email: "nongmail@example.com")
    end

    it "populates the set with normalized emails of abusive accounts" do
      described_class.rebuild!

      expect(described_class.exists?("fraud@gmail.com")).to be(true)
      expect(described_class.exists?("tosviolator@gmail.com")).to be(true)
      expect(described_class.exists?("flagged@gmail.com")).to be(true)
    end

    it "excludes compliant users" do
      described_class.rebuild!

      expect(described_class.exists?("good@gmail.com")).to be(false)
    end

    it "excludes non-Gmail addresses" do
      described_class.rebuild!

      expect(described_class.exists?("nongmail@example.com")).to be(false)
    end

    it "replaces the previous set atomically" do
      described_class.add!("stale@gmail.com")
      described_class.rebuild!

      expect(described_class.exists?("stale@gmail.com")).to be(false)
    end
  end
end
