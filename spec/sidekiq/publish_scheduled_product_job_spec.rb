# frozen_string_literal: true

describe PublishScheduledProductJob do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller, draft: true) }
  let(:schedule) { create(:product_publish_schedule, product:, scheduled_by: seller, publish_at: 1.hour.from_now, version: 3) }

  describe "sidekiq_retries_exhausted" do
    it "fails the schedule it was retrying and queues the failure notice" do
      described_class.sidekiq_retries_exhausted_block.call(
        { "args" => [schedule.id, schedule.version] },
        StandardError.new("boom")
      )

      expect(schedule.reload).to have_attributes(
        status: "failed",
        failure_message: ProductPublishSchedule::GENERIC_FAILURE_MESSAGE
      )
      expect(SendProductPublishScheduleNoticeJob).to have_enqueued_sidekiq_job(schedule.id)
    end

    it "leaves a schedule the seller replaced while the attempt was retrying" do
      replacement_version = schedule.version + 1
      ProductPublishSchedule.where(id: schedule.id).update_all(version: replacement_version)

      described_class.sidekiq_retries_exhausted_block.call(
        { "args" => [schedule.id, schedule.version] },
        StandardError.new("boom")
      )

      expect(schedule.reload).to have_attributes(status: "scheduled", version: replacement_version)
      expect(SendProductPublishScheduleNoticeJob.jobs.size).to eq(0)
    end
  end
end
