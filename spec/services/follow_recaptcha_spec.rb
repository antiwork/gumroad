# frozen_string_literal: true

describe FollowRecaptcha do
  describe ".required?" do
    it "is false for a compliant seller" do
      expect(described_class.required?(create(:compliant_user))).to be(false)
    end

    it "is true for a seller who has not been reviewed" do
      user = create(:user)
      expect(user.user_risk_state).to eq("not_reviewed")

      expect(described_class.required?(user)).to be(true)
    end

    it "is true for a seller on probation or flagged" do
      expect(described_class.required?(create(:user, user_risk_state: "on_probation"))).to be(true)
      expect(described_class.required?(create(:user, user_risk_state: "flagged_for_tos_violation"))).to be(true)
      expect(described_class.required?(create(:user, user_risk_state: "flagged_for_fraud"))).to be(true)
    end

    it "is false when the seller does not resolve" do
      expect(described_class.required?(nil)).to be(false)
    end

    # A deleted account keeps whatever user_risk_state it had, so a seller who
    # was reviewed and marked compliant before deleting their account would
    # otherwise keep taking follows — and every one of those still sends a
    # confirmation email from our sending domain.
    it "is true for a compliant seller whose account has been deleted" do
      user = create(:compliant_user)
      user.mark_deleted!

      expect(user.compliant?).to be(true)
      expect(described_class.required?(user)).to be(true)
    end

    it "is true for a suspended seller" do
      expect(described_class.required?(create(:user, user_risk_state: "suspended_for_fraud"))).to be(true)
      expect(described_class.required?(create(:user, user_risk_state: "suspended_for_tos_violation"))).to be(true)
    end

    it "is false when no site key is configured, so the form is not left with an unsolvable challenge" do
      allow(described_class).to receive(:site_key).and_return(nil)

      expect(described_class.required?(create(:user))).to be(false)
    end

    it "says so in the log when no site key is configured, so a missing key is not silent" do
      allow(described_class).to receive(:site_key).and_return(nil)
      expect(Rails.logger).to receive(:warn).with(/No reCAPTCHA site key is configured/)

      described_class.required?(create(:user))
    end
  end

  describe ".site_key" do
    it "falls back to the checkout key, which is already authorized for every follow-form host" do
      expect(described_class.site_key).to eq(GlobalConfig.get("RECAPTCHA_MONEY_SITE_KEY"))
    end

    it "prefers a follow-specific key when one is configured" do
      allow(GlobalConfig).to receive(:get).and_call_original
      allow(GlobalConfig).to receive(:get).with("RECAPTCHA_FOLLOW_SITE_KEY").and_return("follow-key")

      expect(described_class.site_key).to eq("follow-key")
    end
  end
end
