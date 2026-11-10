# frozen_string_literal: true

require "spec_helper"

describe DispatchProductPublishSchedulesJob do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller, draft: true) }

  before { Feature.activate_user(:scheduled_product_publishing, seller) }

  it "enqueues a publish for a due schedule and leaves a future one alone" do
    due = create(:product_publish_schedule, product:, scheduled_by: seller, publish_at: 1.minute.ago)
    create(:product_publish_schedule, product: create(:product, user: seller, draft: true), scheduled_by: seller, publish_at: 1.hour.from_now)

    described_class.new.perform

    expect(PublishScheduledProductJob.jobs.map { _1["args"] }).to eq([[due.id]])
  end

  it "publishes a due schedule end to end" do
    schedule = create(:product_publish_schedule, product:, scheduled_by: seller, publish_at: 1.minute.ago)

    described_class.new.perform
    PublishScheduledProductJob.drain

    expect(product.reload.draft?).to eq(false)
    expect(schedule.reload.status).to eq("published")
  end

  it "resolves a stale claim and queues its notice" do
    schedule = create(:product_publish_schedule, product:, scheduled_by: seller, status: "publishing", claimed_at: 1.hour.ago)
    described_class.new.perform
    expect(schedule.reload.status).to eq("failed")
    expect(SendProductPublishScheduleNoticeJob).to have_enqueued_sidekiq_job(schedule.id)
  end

  it "resends an unsent failure notice" do
    schedule = create(:product_publish_schedule, product:, scheduled_by: seller, status: "failed", failure_message: "x", updated_at: 1.hour.ago)
    described_class.new.perform
    expect(SendProductPublishScheduleNoticeJob).to have_enqueued_sidekiq_job(schedule.id)
  end

  it "leaves a sent notice alone" do
    create(:product_publish_schedule, product:, scheduled_by: seller, status: "failed", failure_message: "x", notice_sent_at: 1.hour.ago, updated_at: 1.hour.ago)
    described_class.new.perform
    expect(SendProductPublishScheduleNoticeJob.jobs.size).to eq(0)
  end
end
