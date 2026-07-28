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

    it "is false when no site key is configured, so the form is not left with an unsolvable challenge" do
      allow(described_class).to receive(:site_key).and_return(nil)

      expect(described_class.required?(create(:user))).to be(false)
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
