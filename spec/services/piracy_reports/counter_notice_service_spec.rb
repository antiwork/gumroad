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

  it "refuses a report that has no notice out" do
    unsent = create(:piracy_report, :signed)

    result = described_class.new(report: unsent, body: "I own this page.").call

    expect(result).not_to be_success
    expect(unsent.reload).to be_signed
  end

  it "refuses an empty counter-notice" do
    result = described_class.new(report:, body: "   ").call

    expect(result).not_to be_success
    expect(report.reload).to be_sent
  end
end
