# frozen_string_literal: true

require "spec_helper"

describe CheckoutRecaptcha do
  let(:user) { create(:user) }

  before do
    allow(GlobalConfig).to receive(:get).and_call_original
    allow(GlobalConfig).to receive(:get).with("RECAPTCHA_MONEY_SITE_KEY").and_return("money_site_key")
    allow(GlobalConfig).to receive(:get).with("RECAPTCHA_MONEY_SCORE_SITE_KEY").and_return("money_score_site_key")
  end

  describe ".preview_qa_bypass?" do
    # TEMP (preview QA only — revert with the bypass itself, before merge). These specs exist
    # because the bypass disables a fraud control: the important assertions are the negative
    # ones, proving it can never engage with live Stripe keys or off a preview host.
    let(:preview_host) { "presentment-qa-ledger.apps.staging.gumroad.org" }

    context "with Stripe test keys" do
      before { allow(Stripe).to receive(:api_key).and_return("sk_test_abc123") }

      it "is true on a per-PR preview app host" do
        expect(described_class.preview_qa_bypass?(preview_host)).to be(true)
      end

      it "is false on the shared staging host, which also runs test keys" do
        expect(described_class.preview_qa_bypass?("staging.gumroad.com")).to be(false)
      end

      it "is false on the production host" do
        expect(described_class.preview_qa_bypass?("gumroad.com")).to be(false)
      end

      it "is false for a host merely containing the preview suffix elsewhere" do
        expect(described_class.preview_qa_bypass?("apps.staging.gumroad.org.evil.com")).to be(false)
      end

      it "is false for a blank host" do
        expect(described_class.preview_qa_bypass?(nil)).to be(false)
      end
    end

    context "with live Stripe keys (production)" do
      before { allow(Stripe).to receive(:api_key).and_return("sk_live_abc123") }

      it "is false even on a preview host" do
        expect(described_class.preview_qa_bypass?(preview_host)).to be(false)
      end

      it "is false in development, so a misconfigured live key cannot open the bypass" do
        allow(Rails.env).to receive(:development?).and_return(true)

        expect(described_class.preview_qa_bypass?("localhost")).to be(false)
      end
    end
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

    it "is :checkout_score for an untrusted buyer in the cohort" do
      Feature.activate_user(:recaptcha_score_checkout, user)

      expect(described_class.surface(user)).to eq(:checkout_score)
    end

    context "for a trusted buyer in the cohort" do
      before { Feature.activate_user(:recaptcha_score_checkout, user) }

      it "is :checkout_score_trusted when the buyer is themselves a compliant seller" do
        user.update!(user_risk_state: "compliant")

        expect(described_class.surface(user)).to eq(:checkout_score_trusted)
      end

      it "is :checkout_score_trusted when the buyer has an aged paid purchase from a compliant seller" do
        compliant_seller = create(:compliant_user)
        create(:purchase, link: create(:product, user: compliant_seller), purchaser: user, created_at: 6.years.ago)

        expect(described_class.surface(user)).to eq(:checkout_score_trusted)
      end

      it "is :checkout_score when the buyer's purchase from a compliant seller is too recent" do
        compliant_seller = create(:compliant_user)
        create(:purchase, link: create(:product, user: compliant_seller), purchaser: user, created_at: 1.year.ago)

        expect(described_class.surface(user)).to eq(:checkout_score)
      end

      it "is :checkout_score when the buyer's aged paid purchase is from a non-compliant seller" do
        non_compliant_seller = create(:user)
        create(:purchase, link: create(:product, user: non_compliant_seller), purchaser: user, created_at: 6.years.ago)

        expect(described_class.surface(user)).to eq(:checkout_score)
      end
    end

    it "is :checkout for an anonymous buyer when the cohort is only enabled per-user" do
      Feature.activate_user(:recaptcha_score_checkout, user)

      expect(described_class.surface(nil)).to eq(:checkout)
    end

    context "when the cohort feature is enabled globally" do
      before { Feature.activate(:recaptcha_score_checkout) }

      it "puts an anonymous buyer on the untrusted score surface without raising" do
        expect(described_class.score_based?(nil)).to be(true)
        expect(described_class.surface(nil)).to eq(:checkout_score)
      end

      it "still routes a trusted logged-in buyer to the trusted surface" do
        user.update!(user_risk_state: "compliant")

        expect(described_class.surface(user)).to eq(:checkout_score_trusted)
      end
    end
  end
end
