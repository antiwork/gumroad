# frozen_string_literal: true

require "spec_helper"

describe ReleaseChargebackRatePayoutPausesJob do
  def pause_for_chargeback_rate!(user)
    user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)
    user.comments.create!(
      content: "Payouts automatically paused due to chargeback rate (4.2%) exceeding 3.0% volume.",
      comment_type: Comment::COMMENT_TYPE_ON_PROBATION,
      author_name: User::SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS[:high_chargeback_rate]
    )
  end

  it "enqueues a per-seller re-check for a seller held by the chargeback-rate pause" do
    user = create(:user)
    pause_for_chargeback_rate!(user)

    described_class.new.perform

    expect(ReleaseChargebackRatePayoutPauseForSellerJob).to have_enqueued_sidekiq_job(user.id)
  end

  it "enqueues each seller only once even with several pause comments" do
    user = create(:user)
    pause_for_chargeback_rate!(user)
    pause_for_chargeback_rate!(user)

    described_class.new.perform

    expect(ReleaseChargebackRatePayoutPauseForSellerJob.jobs.size).to eq(1)
  end

  it "ignores sellers paused by the repeated-failed-payouts check" do
    user = create(:user)
    user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)
    user.comments.create!(
      content: "Payouts paused automatically after 3 consecutive failed payouts.",
      comment_type: Comment::COMMENT_TYPE_ON_PROBATION,
      author_name: User::SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS[:repeated_failed_payouts]
    )

    described_class.new.perform

    expect(ReleaseChargebackRatePayoutPauseForSellerJob.jobs.size).to eq(0)
  end

  it "ignores deleted pause comments" do
    user = create(:user)
    pause_for_chargeback_rate!(user).mark_deleted!

    described_class.new.perform

    expect(ReleaseChargebackRatePayoutPauseForSellerJob.jobs.size).to eq(0)
  end

  it "is registered in the sidekiq schedule" do
    schedule_classes = YAML.load_file(Rails.root.join("config", "sidekiq_schedule.yml")).values.map { _1["class"] }
    expect(schedule_classes).to include(described_class.name)
  end
end
