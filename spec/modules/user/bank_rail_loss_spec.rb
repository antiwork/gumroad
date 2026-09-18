# frozen_string_literal: true

require "spec_helper"

describe User::FeatureStatus, "bank rail loss on PayPal switch" do
  let(:user) { create(:named_user) }

  describe "#paypal_switch_loses_bank_rail?" do
    it "is true for an India seller with an active bank account (Stripe refuses new IND accounts)" do
      create(:user_compliance_info, user:, country: "India")
      create(:indian_bank_account, user:)

      expect(user.can_setup_bank_payouts?).to be(true)
      expect(user.paypal_switch_loses_bank_rail?).to be(true)
    end

    it "is false once the India seller has no bank account left to lose" do
      create(:user_compliance_info, user:, country: "India")

      expect(user.can_setup_bank_payouts?).to be(false)
      expect(user.paypal_switch_loses_bank_rail?).to be(false)
    end

    it "is false where the country can re-create the rail" do
      create(:user_compliance_info, user:, country: "Japan")
      create(:japan_bank_account, user:)

      expect(user.paypal_switch_loses_bank_rail?).to be(false)
    end
  end
end
