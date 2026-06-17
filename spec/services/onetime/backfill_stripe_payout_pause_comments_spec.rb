# frozen_string_literal: true

require "spec_helper"

describe Onetime::BackfillStripePayoutPauseComments do
  describe ".process" do
    def stripe_paused_user
      create(:user).tap do |user|
        user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_STRIPE)
      end
    end

    it "writes a payouts_paused comment with the stored Stripe reason for a Stripe-paused user that has none" do
      user = stripe_paused_user
      create(:merchant_account, user:, charge_processor_merchant_id: "acct_one", stripe_disabled_reason: "listed")

      expect do
        described_class.process
      end.to change { user.comments.with_type_payouts_paused.count }.from(0).to(1)

      comment = user.comments.with_type_payouts_paused.last
      expect(comment.content).to include("listed")
      expect(comment.author_name).to eq("Stripe payouts sync")
      expect(user.reload.payouts_paused_for_reason).to include("listed")
    end

    it "is idempotent and does not write a second comment when the latest comment already matches" do
      user = stripe_paused_user
      merchant_account = create(:merchant_account, user:, charge_processor_merchant_id: "acct_two", stripe_disabled_reason: "listed")
      user.comments.create!(
        author_name: "Stripe payouts sync",
        comment_type: Comment::COMMENT_TYPE_PAYOUTS_PAUSED,
        content: merchant_account.stripe_payouts_paused_comment
      )

      expect do
        described_class.process
        described_class.process
      end.not_to change { user.comments.with_type_payouts_paused.count }
    end

    it "writes the Stripe reason even when an older, mismatched payouts_paused comment exists" do
      user = stripe_paused_user
      create(:merchant_account, user:, charge_processor_merchant_id: "acct_six", stripe_disabled_reason: "listed")
      user.comments.create!(
        author_name: "admin",
        comment_type: Comment::COMMENT_TYPE_PAYOUTS_PAUSED,
        content: "Payouts paused by an admin for an unrelated earlier reason."
      )

      expect do
        described_class.process
      end.to change { user.comments.with_type_payouts_paused.count }.by(1)

      expect(user.reload.payouts_paused_for_reason).to include("listed")
    end

    it "skips users whose payouts are paused by the system, not Stripe" do
      user = create(:user)
      user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)
      create(:merchant_account, user:, charge_processor_merchant_id: "acct_three", stripe_disabled_reason: "listed")

      expect { described_class.process }.not_to change { Comment.with_type_payouts_paused.count }
    end

    it "skips users whose payouts are not paused" do
      user = create(:user)
      create(:merchant_account, user:, charge_processor_merchant_id: "acct_four", stripe_disabled_reason: "listed")

      expect { described_class.process }.not_to change { Comment.with_type_payouts_paused.count }
    end

    it "skips Stripe Connect accounts" do
      user = stripe_paused_user
      merchant_account = create(:merchant_account, user:, charge_processor_merchant_id: "acct_five", stripe_disabled_reason: "listed")
      merchant_account.update!(json_data: merchant_account.json_data.deep_merge("meta" => { "stripe_connect" => "true" }))

      expect { described_class.process }.not_to change { user.comments.with_type_payouts_paused.count }
    end

    it "writes one comment from the canonical account and stays idempotent when a user has multiple Stripe accounts" do
      user = stripe_paused_user
      create(:merchant_account, user:, charge_processor_merchant_id: "acct_a", stripe_disabled_reason: "requirements.past_due")
      create(:merchant_account, user:, charge_processor_merchant_id: "acct_b", stripe_disabled_reason: "listed")
      canonical_reason = user.stripe_account.stripe_payouts_paused_comment

      expect do
        described_class.process
        described_class.process
      end.to change { user.comments.with_type_payouts_paused.count }.from(0).to(1)

      expect(user.reload.payouts_paused_for_reason).to eq(canonical_reason)
    end
  end
end
