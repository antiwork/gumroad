# frozen_string_literal: true

require "spec_helper"

describe Product::Recommendations, :elasticsearch_wait_for_refresh do
  context "when user is recommendable" do
    let(:user) { create(:recommendable_user) }

    it "is recommendable" do
      expect(user.recommendable_reasons.values).to all(be true)
      expect(user.recommendable?).to be(true)
    end
  end

  context "when user is deleted" do
    let(:user) { create(:recommendable_user, :deleted) }

    it "is not recommendable" do
      expect(user.recommendable_reasons[:not_deleted]).to be(false)
      expect(user.recommendable_reasons.except(:not_deleted).values).to all(be true)
      expect(user.recommendable?).to be(false)
    end
  end

  describe "payout info" do
    let(:user) { create(:compliant_user) }

    it "is false if user doesn't have payout info" do
      user.update!(payment_address: nil)
      expect(user.recommendable_reasons[:payout_filled]).to be(false)
      expect(user.recommendable_reasons.except(:payout_filled).values).to all(be true)
      expect(user.recommendable?).to be(false)
    end

    it "is true if user has payment_address" do
      expect(user.recommendable_reasons[:payout_filled]).to be(true)
      expect(user.recommendable?).to be(true)
    end

    it "is true if user has active bank_account" do
      user.update!(payment_address: nil)
      create(:canadian_bank_account, user:)
      expect(user.recommendable_reasons[:payout_filled]).to be(true)
      expect(user.recommendable?).to be(true)
    end

    it "is true if user has a paypal account connected" do
      user.update!(payment_address: nil)
      create(:merchant_account_paypal, charge_processor_merchant_id: "CJS32DZ7NDN5L", user:, country: "GB", currency: "gbp")
      expect(user.recommendable_reasons[:payout_filled]).to be(true)
      expect(user.recommendable?).to be(true)
    end
  end
end
