# frozen_string_literal: true

require "spec_helper"

describe AlertOnPiracyReportsBlockedOnRecipientJob do
  def blocked_report(url: "https://unlisted.example.org/course")
    create(:piracy_report, :screening, url:, screened_at: Time.current)
  end

  def message
    captured = nil
    allow(InternalNotificationWorker).to receive(:perform_async) { |_room, _subject, body| captured = body }
    described_class.new.perform
    captured
  end

  before { allow(InternalNotificationWorker).to receive(:perform_async) }

  it "reports a report that passed screening but has no verified recipient" do
    report = blocked_report

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |room, subject, body|
      expect(room).to eq("risk")
      expect(subject).to eq("Piracy reports blocked on a missing recipient")
      expect(body).to include("1 piracy report passed screening but the reported host has no verified contact")
      expect(body).to include(report.external_id)
      expect(body).to include("unlisted.example.org")
      expect(body).to include("config/piracy_recipients.yml")
    end
  end

  it "stays silent when no report is blocked" do
    create(:piracy_report, :screening)
    create(:piracy_report, :awaiting_signature)

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "reports at most MAX_REPORTED reports and says the list is truncated" do
    (described_class::MAX_REPORTED + 1).times { |i| blocked_report(url: "https://unlisted.example.org/course-#{i}") }

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _subject, body|
      expect(body).to include("At least #{described_class::MAX_REPORTED + 1} piracy reports")
      expect(body).to include("Only the first #{described_class::MAX_REPORTED} are listed.")
      expect(body.scan("• ").size).to eq(described_class::MAX_REPORTED)
    end
  end
end
