# frozen_string_literal: true

require "spec_helper"

describe DispatchProductPublishSchedulesJob do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller, draft: true) }

  before { Feature.activate_user(:scheduled_product_publishing, seller) }

  it "re-enqueues a due schedule whose job was lost" do
    schedule = ProductPublishSchedule.schedule!(product:, scheduled_by: seller, local_time: (Time.current + 1.hour).in_time_zone(seller.timezone_id).strftime("%Y-%m-%dT%H:%M"))
    schedule.update_columns(publish_at: 2.minutes.ago)
    PublishScheduledProductJob.jobs.clear

    described_class.new.perform
    expect(PublishScheduledProductJob).to have_enqueued_sidekiq_job(schedule.id, schedule.version)
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
end
