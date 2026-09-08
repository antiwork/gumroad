# frozen_string_literal: true

require "spec_helper"

describe SocialScoreShadowEvaluationService do
  let(:user) { create(:user, user_risk_state: "flagged_for_fraud") }

  def strong_verification(owner = user)
    linked_verification(
      user: owner,
      account_created_at: 5.years.ago,
      follower_count: 5_000,
      post_count: 1_000,
      last_posted_at: 1.week.ago,
      last_verified_at: 1.day.ago,
    )
  end

  def linked_verification(**attributes)
    verification = create(:social_connect_verification, **attributes)
    case verification.platform
    when "twitter"
      verification.user.update!(twitter_user_id: verification.uid)
    when "youtube"
      create(:user_youtube_identity, user: verification.user, channel_id: verification.uid)
    when "instagram"
      create(:user_instagram_identity, user: verification.user, instagram_user_id: verification.uid)
    end
    verification
  end

  before do
    allow(user).to receive(:unpaid_balance_cents).and_return(50_00)
  end

  describe "#evaluate" do
    %w[twitter youtube instagram].each do |platform|
      it "scores a currently linked #{platform} identity" do
        linked_verification(user:, platform:, account_created_at: platform == "instagram" ? nil : 5.years.ago)

        result = described_class.new(user).evaluate

        expect(result[:score]).to eq(platform == "instagram" ? 55 : 85)
        expect(result[:would_have_released]).to be(true)
      end

      it "ignores a mismatched #{platform} verification UID" do
        verification = linked_verification(user:, platform:)
        verification.update!(uid: "old-identity")

        expect(described_class.new(user).evaluate).to include(score: 0, would_have_released: false, signals: nil)
      end

      it "ignores a #{platform} verification without a live identity" do
        create(:social_connect_verification, user:, platform:)

        expect(described_class.new(user).evaluate).to include(score: 0, would_have_released: false, signals: nil)
      end
    end

    it "ignores a retained strong Twitter verification after disconnect" do
      strong_verification
      user.update!(twitter_user_id: nil)

      expect(described_class.new(user).evaluate).to include(score: 0, would_have_released: false, signals: nil)
      expect(user.social_connect_verifications.count).to eq(1)
    end

    it "ignores unsupported platforms even with strong verified signals" do
      create(:social_connect_verification, user:, platform: "tiktok")

      expect(described_class.new(user).evaluate).to include(score: 0, would_have_released: false, signals: nil)
    end

    [1.day, 1.year, nil].each do |verification_age|
      it "retains a disconnected non-best shared identity veto with verification age #{verification_age.inspect}" do
        strong_verification
        historical = create(:social_connect_verification, user:, platform: "youtube")
        historical.update_columns(last_verified_at: verification_age&.ago)
        create(:social_connect_verification, platform: "youtube", uid: historical.uid)

        expect(described_class.new(user).evaluate).to include(score: 85, would_have_released: false)
      end
    end

    it "returns nil for a deleted seller despite strong currently linked signals" do
      strong_verification
      user.update_columns(deleted_at: Time.current)

      expect(described_class.new(user).evaluate).to be_nil
    end

    it "returns nil when the user has no held payout" do
      strong_verification
      user.update!(user_risk_state: "compliant")

      expect(described_class.new(user).evaluate).to be_nil
    end

    it "returns nil when the held balance is zero" do
      strong_verification
      allow(user).to receive(:unpaid_balance_cents).and_return(0)

      expect(described_class.new(user).evaluate).to be_nil
    end

    it "returns nil for suspended users even when payouts are also paused internally" do
      strong_verification
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

    it "reads each historical identity once per evaluation" do
      strong_verification
      create(:social_connect_verification, user:, platform: "youtube")
      user.social_connect_verifications.reload.each do |verification|
        expect(verification).to receive(:shared_identity_user_ids).once.and_call_original
      end

      expect(described_class.new(user).evaluate).to include(score: 85, would_have_released: true)
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
      weak = linked_verification(
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
      linked_verification(
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

    it "prefers a threshold-passing Instagram score over a higher raw score that misses its own threshold" do
      linked_verification(
        user:,
        platform: "twitter",
        account_created_at: 3.months.ago,
        follower_count: 100_000,
        post_count: 5_000,
        last_posted_at: 1.day.ago,
      )
      linked_verification(
        user:,
        platform: "instagram",
        account_created_at: nil,
        follower_count: 5_000,
        post_count: 1_000,
        last_posted_at: 1.day.ago,
      )

      result = described_class.new(user).evaluate

      expect(result[:signals][:platform]).to eq("instagram")
      expect(result[:score]).to eq(55)
      expect(result[:would_have_released]).to be(true)
    end

    it "uses all available Instagram signals instead of requiring an unavailable account age" do
      linked_verification(
        user:,
        platform: "instagram",
        account_created_at: nil,
        follower_count: 5_000,
        post_count: 1_000,
        last_posted_at: 1.day.ago,
      )

      result = described_class.new(user).evaluate

      expect(result[:score]).to eq(55)
      expect(result[:signals][:release_threshold]).to eq(55)
      expect(result[:would_have_released]).to be(true)
    end

    it "does not release an Instagram account without every available signal" do
      linked_verification(
        user:,
        platform: "instagram",
        account_created_at: nil,
        follower_count: 500,
        post_count: 1_000,
        last_posted_at: 1.day.ago,
      )

      result = described_class.new(user).evaluate

      expect(result[:score]).to eq(40)
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
