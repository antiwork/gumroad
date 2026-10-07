# frozen_string_literal: true

require "spec_helper"

describe PiracyReports::CounterNoticeService do
  let(:report) { create(:piracy_report, :sent) }
  let(:received_at) { 2.days.ago.change(usec: 0) }

  it "records the counter-notice and tells the seller what it starts" do
    expect do
      result = described_class.new(report:, body: "  I own this page.  ", received_at:).call
      expect(result).to be_success
    end.to have_enqueued_mail(PiracyReportMailer, :counter_notice_received).with(report.id)

    expect(report.reload).to be_counter_noticed
    expect(report.counter_notice_body).to eq("I own this page.")
    expect(report.counter_notice_received_at).to eq(received_at)
    expect(report.counter_notice_forwarded_at).to be_present
  end

  it "keeps the response but leaves the forwarding unrecorded when the seller cannot be told" do
    allow(PiracyReportMailer).to receive(:counter_notice_received).and_raise(StandardError, "redis down")

    result = described_class.new(report:, body: "I own this page.", received_at:).call

    expect(result).not_to be_success
    expect(result.errors.first).to include("The seller could not be told")
    report.reload
    expect(report).to be_counter_noticed
    expect(report.counter_notice_received_at).to eq(received_at)
    expect(report.counter_notice_forwarded_at).to be_nil
  end

  it "sends the warning on a second run without moving the recorded clock" do
    allow(PiracyReportMailer).to receive(:counter_notice_received).and_raise(StandardError, "redis down")
    described_class.new(report:, body: "I own this page.", received_at:).call
    allow(PiracyReportMailer).to receive(:counter_notice_received).and_call_original

    result = nil
    expect { result = described_class.new(report: report.reload, body: "ignored", received_at: 1.day.ago).call }
      .to have_enqueued_mail(PiracyReportMailer, :counter_notice_received).with(report.id)

    expect(result).to be_success
    expect(report.reload.counter_notice_received_at).to eq(received_at)
    expect(report.counter_notice_forwarded_at).to be_present
  end

  it "refuses a report that has no notice out" do
    unsent = create(:piracy_report, :signed)

    result = described_class.new(report: unsent, body: "I own this page.", received_at:).call

    expect(result).not_to be_success
    expect(unsent.reload).to be_signed
  end

  it "refuses an empty counter-notice" do
    result = described_class.new(report:, body: "   ", received_at:).call

    expect(result).not_to be_success
    expect(report.reload).to be_sent
  end

  it "refuses a counter-notice with no receipt date" do
    result = described_class.new(report:, body: "I own this page.", received_at: nil).call

    expect(result.errors).to include("The counter-notice has no received date")
    expect(report.reload).to be_sent
  end
end
