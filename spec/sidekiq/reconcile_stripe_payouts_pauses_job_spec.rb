# frozen_string_literal: true

require "spec_helper"

describe ReconcileStripePayoutsPausesJob do
  def pause_by_stripe!(user)
    user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_STRIPE)
    user.comments.create!(
      content: "Payouts automatically paused by Stripe (disabled reason: requirements.past_due).",
      comment_type: Comment::COMMENT_TYPE_PAYOUTS_PAUSED,
      author_name: StripeMerchantAccountManager::STRIPE_PAYOUTS_SYNC_COMMENT_AUTHOR
    )
  end

  it "queues a per-seller re-check for a seller Stripe paused" do
    user = create(:user)
    pause_by_stripe!(user)

    described_class.new.perform

    expect(ReconcileStripePayoutsPauseForSellerJob).to have_enqueued_sidekiq_job(user.id)
  end

  it "enqueues each seller only once even with several historical pause comments" do
    user = create(:user)
    pause_by_stripe!(user)
    pause_by_stripe!(user)

    described_class.new.perform

    expect(ReconcileStripePayoutsPauseForSellerJob.jobs.size).to eq(1)
  end

  it "ignores payout pauses written by any other author" do
    user = create(:user)
    user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)
    user.comments.create!(
      content: "Payouts paused automatically after 3 consecutive failed payouts.",
      comment_type: Comment::COMMENT_TYPE_PAYOUTS_PAUSED,
      author_name: User::SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS[:repeated_failed_payouts]
    )

    described_class.new.perform

    expect(ReconcileStripePayoutsPauseForSellerJob.jobs).to be_empty
  end
end
