# frozen_string_literal: true

require "spec_helper"

describe AlertOnStuckPiracyReportsJob do
  def blocked_report(url: "https://unlisted.example.org/course")
    create(:piracy_report, :screening, url:, screening_verdict: "pass", screened_at: Time.current)
  end

  def review_report(url: "https://undecided.example.org/course")
    create(:piracy_report, :screening, url:, screening_verdict: "review", screened_at: Time.current)
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
      expect(subject).to eq("Piracy reports waiting in screening")
      expect(body).to include("1 piracy report passed screening but the reported host has no verified contact")
      expect(body).to include(report.external_id)
      expect(body).to include("unlisted.example.org")
      expect(body).to include("config/piracy_recipients.yml")
    end
  end

  it "reports a report the agent could not decide, in its own section" do
    blocked = blocked_report
    undecided = review_report

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async).once do |_room, _subject, body|
      blocked_part, review_part = body.split("\n\n1 piracy report could not be decided")
      expect(blocked_part).to include(blocked.external_id)
      expect(blocked_part).not_to include(undecided.external_id)
      expect(review_part).to include(undecided.external_id, "undecided.example.org", "Gumclaw works this queue")
    end
  end

  it "starts with the review section when no report is blocked" do
    undecided = review_report

    expect(message).to start_with("1 piracy report could not be decided by the screening agent.\n\n• #{undecided.external_id}")
  end

  it "stays silent when no report is blocked or waiting for review" do
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
