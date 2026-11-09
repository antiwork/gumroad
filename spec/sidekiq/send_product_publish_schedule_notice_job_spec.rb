# frozen_string_literal: true

require "spec_helper"

describe SendProductPublishScheduleNoticeJob do
  let(:product) { create(:product, draft: true) }

  it "sends the success mail once with the local time" do
    schedule = create(:product_publish_schedule, product:, status: "published", published_at: Time.utc(2026, 12, 2, 17, 30))
    described_class.new.perform(schedule.id)
    described_class.new.perform(schedule.id)

    mails = ActionMailer::Base.deliveries.select { _1.subject == "#{product.name} is live" }
    expect(mails.size).to eq(1)
    expect(mails.first.body.encoded).to include("9:30 AM PST")
    expect(ProductPublishSchedule.exists?(schedule.id)).to eq(false)
  end

  it "sends the failure mail once" do
    schedule = create(:product_publish_schedule, product:, status: "failed", failure_message: "Gate failed")
    described_class.new.perform(schedule.id)
    described_class.new.perform(schedule.id)

    mails = ActionMailer::Base.deliveries.select { _1.subject == "#{product.name} was not published" }
    expect(mails.size).to eq(1)
    expect(mails.first.body.encoded).to include("Gate failed")
    expect(schedule.reload.notice_sent_at).to be_present
  end
end
