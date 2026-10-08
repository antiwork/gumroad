# frozen_string_literal: true

require "spec_helper"

describe PiracyReports::CounterNoticeService do
  let(:report) { create(:piracy_report, :signed, state: "sent", sent_at: 3.days.ago, last_contact_email: "seller@example.com") }

  def call(body: "I own a license for this course.", received_on: 1.day.ago.to_date.iso8601, on: report)
    described_class.new(report: on, body:, received_on:).call
  end

  it "records the counter-notice with the host's receipt date and forwards it to the seller at once" do
    freeze_time do
      expect { expect(call(received_on: "2026-10-07")).to be_success }
        .to have_enqueued_mail(PiracyReportMailer, :counter_notice_received).with(report.id)

      expect(report.reload).to have_attributes(
        state: "counter_noticed",
        counter_notice_body: "I own a license for this course.",
        counter_notice_received_on: Date.new(2026, 10, 7),
        counter_notice_forwarded_at: Time.current
      )
    end
  end

  it "refuses a report that has no notice out with a host" do
    signed = create(:piracy_report, :signed)

    expect(call(on: signed).errors).to eq(["The report has no notice out with a host"])
    expect(signed.reload.state).to eq("signed")
  end

  it "requires a body and a YYYY-MM-DD receipt date between the send date and today" do
    date_error = "received_on must be a YYYY-MM-DD date between the send date and today"

    expect(call(body: " ", received_on: 3.days.from_now.to_date.iso8601).errors).to contain_exactly("body is required", date_error)
    expect(call(received_on: 10.days.ago.to_date.iso8601).errors).to eq([date_error])
    ["yesterday", "20261008", "2026-W41-4", "1" * 200].each { expect(call(received_on: _1).errors).to eq([date_error]) }
    expect(report.reload.state).to eq("sent")
  end

  it "accepts the host's date when it is a day ahead of UTC" do
    expect(call(received_on: Date.current.next_day.iso8601)).to be_success
  end

  it "says so when a counter-notice is already recorded" do
    call

    expect(call.errors).to eq(["A counter-notice is already recorded for this report"])
  end
end
