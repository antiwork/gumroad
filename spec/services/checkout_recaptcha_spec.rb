# frozen_string_literal: true

require "spec_helper"

describe CheckoutRecaptcha do
  let(:user) { create(:user) }

  before do
    allow(GlobalConfig).to receive(:get).and_call_original
    allow(GlobalConfig).to receive(:get).with("RECAPTCHA_MONEY_SITE_KEY").and_return("money_site_key")
    allow(GlobalConfig).to receive(:get).with("RECAPTCHA_MONEY_SCORE_SITE_KEY").and_return("money_score_site_key")
  end

  describe ".score_based?" do
    it "is false for a buyer not in the cohort" do
      expect(described_class.score_based?(user)).to be(false)
    end

    it "is true for a buyer in the cohort" do
      Feature.activate_user(:recaptcha_score_checkout, user)

      expect(described_class.score_based?(user)).to be(true)
    end

    it "is false for an anonymous buyer even when other buyers are in the cohort" do
      Feature.activate_user(:recaptcha_score_checkout, user)

      expect(described_class.score_based?(nil)).to be(false)
    end

    it "is false when the score key is not configured" do
      allow(GlobalConfig).to receive(:get).with("RECAPTCHA_MONEY_SCORE_SITE_KEY").and_return(nil)
      Feature.activate_user(:recaptcha_score_checkout, user)

      expect(described_class.score_based?(user)).to be(false)
    end
  end

  describe ".site_key" do
    it "returns the challenge key for a buyer not in the cohort" do
      expect(described_class.site_key(user)).to eq("money_site_key")
    end

    it "returns the score key for a buyer in the cohort" do
      Feature.activate_user(:recaptcha_score_checkout, user)

      expect(described_class.site_key(user)).to eq("money_score_site_key")
    end

    it "falls back to the challenge key when the score key is not configured" do
      allow(GlobalConfig).to receive(:get).with("RECAPTCHA_MONEY_SCORE_SITE_KEY").and_return(nil)
      Feature.activate_user(:recaptcha_score_checkout, user)

      expect(described_class.site_key(user)).to eq("money_site_key")
    end
  end

  describe ".surface" do
    it "is :checkout for a buyer not in the cohort" do
      expect(described_class.surface(user)).to eq(:checkout)
    end

    it "is :checkout_score for a buyer in the cohort" do
      Feature.activate_user(:recaptcha_score_checkout, user)

      expect(described_class.surface(user)).to eq(:checkout_score)
    end
  end
end
