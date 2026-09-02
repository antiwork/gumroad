# frozen_string_literal: true

require "spec_helper"

describe RecordSocialScoreShadowEvaluationsJob do
  describe "#perform" do
    it "records one row per held seller with a verification and skips unheld sellers" do
      held = create(:user, user_risk_state: "flagged_for_fraud")
      create(:social_connect_verification, user: held)
      create(:balance, user: held, amount_cents: 100_00)

      unheld = create(:user, user_risk_state: "compliant")
      create(:social_connect_verification, user: unheld)
      create(:balance, user: unheld, amount_cents: 100_00)

      expect { described_class.new.perform }.to change(SocialScoreShadowEvaluation, :count).by(1)

      evaluation = SocialScoreShadowEvaluation.last
      expect(evaluation.user).to eq(held)
      expect(evaluation.evaluated_on).to eq(Date.current)
      expect(evaluation.hold_source).to eq("risk_state_flagged_for_fraud")
      expect(evaluation.would_have_released).to be(false)
    end

    it "is idempotent within a day, updating the existing row" do
      held = create(:user, user_risk_state: "flagged_for_fraud")
      create(:social_connect_verification, user: held)
      create(:balance, user: held, amount_cents: 100_00)

      described_class.new.perform

      expect { described_class.new.perform }.not_to change(SocialScoreShadowEvaluation, :count)
    end

    it "never mutates payout or risk state" do
      held = create(:user, user_risk_state: "flagged_for_fraud")
      create(:social_connect_verification, user: held, account_created_at: 5.years.ago,
                                           follower_count: 5_000, post_count: 1_000, last_posted_at: 1.week.ago)
      create(:balance, user: held, amount_cents: 100_00)

      described_class.new.perform

      held.reload
      expect(held.user_risk_state).to eq("flagged_for_fraud")
      expect(held.payouts_paused?).to be(false)
      expect(SocialScoreShadowEvaluation.last.would_have_released).to be(true)
    end

    it "continues past a seller whose evaluation raises" do
      failing = create(:user, user_risk_state: "flagged_for_fraud")
      create(:social_connect_verification, user: failing)
      create(:balance, user: failing, amount_cents: 100_00)

      fine = create(:user, user_risk_state: "flagged_for_fraud")
      create(:social_connect_verification, user: fine)
      create(:balance, user: fine, amount_cents: 100_00)

      allow(SocialScoreShadowEvaluationService).to receive(:new).and_call_original
      allow(SocialScoreShadowEvaluationService).to receive(:new)
        .with(having_attributes(id: failing.id)).and_raise(StandardError, "boom")

      expect { described_class.new.perform }.to change(SocialScoreShadowEvaluation, :count).by(1)
      expect(SocialScoreShadowEvaluation.last.user).to eq(fine)
    end
  end
end
