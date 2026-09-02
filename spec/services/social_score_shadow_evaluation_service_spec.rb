# frozen_string_literal: true

require "spec_helper"

describe SocialScoreShadowEvaluationService do
  let(:user) { create(:user, user_risk_state: "flagged_for_fraud") }

  def strong_verification(owner = user)
    create(
      :social_connect_verification,
      user: owner,
      account_created_at: 5.years.ago,
      follower_count: 5_000,
      post_count: 1_000,
      last_posted_at: 1.week.ago,
      last_verified_at: 1.day.ago,
    )
  end

  before do
    allow(user).to receive(:unpaid_balance_cents).and_return(50_00)
  end

  describe "#evaluate" do
    it "returns nil when the user has no held payout" do
      user.update!(user_risk_state: "compliant")

      expect(described_class.new(user).evaluate).to be_nil
    end

    it "returns nil when the held balance is zero" do
      allow(user).to receive(:unpaid_balance_cents).and_return(0)

      expect(described_class.new(user).evaluate).to be_nil
    end

    it "returns nil for suspended users even when payouts are also paused internally" do
      # Suspended states are already outside REVIEWABLE_RISK_STATES; the pause is what would
      # otherwise classify this account as held, so it is what proves the suspended guard bites.
      user.update_columns(user_risk_state: "suspended_for_fraud")
      user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_ADMIN)

      expect(described_class.new(user).evaluate).to be_nil
    end

    it "returns nil for a seller-initiated payout pause" do
      user.update!(user_risk_state: "compliant")
      user.update!(payouts_paused_by_user: true)

      expect(described_class.new(user).evaluate).to be_nil
    end

    it "still scores a self-paused seller whose risk state is reviewable" do
      user.update!(payouts_paused_by_user: true)

      result = described_class.new(user).evaluate

      expect(result[:hold_source]).to eq("risk_state_flagged_for_fraud")
    end

    it "still scores a Stripe-paused seller whose risk state is reviewable" do
      user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_STRIPE)

      result = described_class.new(user).evaluate

      expect(result[:hold_source]).to eq("risk_state_flagged_for_fraud")
    end

    it "returns nil for a Stripe-sourced payout pause" do
      user.update!(user_risk_state: "compliant")
      user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_STRIPE)

      expect(described_class.new(user).evaluate).to be_nil
    end

    it "scores zero with no would-have-released for a held seller without verifications" do
      result = described_class.new(user).evaluate

      expect(result[:score]).to eq(0)
      expect(result[:would_have_released]).to be(false)
      expect(result[:hold_source]).to eq("risk_state_flagged_for_fraud")
      expect(result[:unpaid_balance_cents]).to eq(50_00)
    end

    it "marks would_have_released for a strong verification above the threshold" do
      strong_verification

      result = described_class.new(user).evaluate

      expect(result[:score]).to be >= described_class::RELEASE_THRESHOLD
      expect(result[:would_have_released]).to be(true)
      expect(result[:signals][:platform]).to eq("twitter")
    end

    it "does not release when the social identity vouches for another Gumroad account" do
      verification = strong_verification
      create(:social_connect_verification, user: create(:user), uid: verification.uid)

      result = described_class.new(user).evaluate

      expect(result[:score]).to be >= described_class::RELEASE_THRESHOLD
      expect(result[:would_have_released]).to be(false)
    end

    it "does not release when a weaker, non-best verification carries the shared identity" do
      strong_verification
      weak = create(
        :social_connect_verification,
        user:,
        platform: "youtube",
        account_created_at: 1.month.ago,
        follower_count: 0,
        post_count: 0,
        last_posted_at: nil,
        last_verified_at: 1.day.ago,
      )
      create(:social_connect_verification, user: create(:user), platform: "youtube", uid: weak.uid)

      result = described_class.new(user).evaluate

      expect(result[:score]).to be >= described_class::RELEASE_THRESHOLD
      expect(result[:would_have_released]).to be(false)
    end

    it "does not release on a young account even with a large following" do
      create(
        :social_connect_verification,
        user:,
        account_created_at: 3.months.ago,
        follower_count: 100_000,
        post_count: 5_000,
        last_posted_at: 1.day.ago,
      )

      result = described_class.new(user).evaluate

      expect(result[:score]).to be < described_class::RELEASE_THRESHOLD
      expect(result[:would_have_released]).to be(false)
    end

    it "ignores stale verifications" do
      strong_verification.update!(last_verified_at: 1.year.ago)

      result = described_class.new(user).evaluate

      expect(result[:score]).to eq(0)
      expect(result[:would_have_released]).to be(false)
    end

    it "uses the internal payout pause as the hold source for a compliant paused seller" do
      user.update!(user_risk_state: "compliant")
      user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_ADMIN)

      result = described_class.new(user).evaluate

      expect(result[:hold_source]).to eq("payout_pause_admin")
    end
  end
end
