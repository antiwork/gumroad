# frozen_string_literal: true

require "spec_helper"

describe PiracyReports::CounterNoticeService do
  let(:report) { create(:piracy_report, :signed, state: "sent", sent_at: 3.days.ago, last_contact_email: "seller@example.com") }

  def call(body: "I own a license for this course.", received_on: 1.day.ago.to_date.iso8601, on: report)
    described_class.new(report: on, body:, received_on:).call
  end

  it "records the counter-notice with the host's receipt date and forwards it to the seller at once" do
    travel_to(Time.utc(2026, 10, 9, 12)) do
      report.update!(sent_at: Time.utc(2026, 10, 6, 12))

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

  it "accepts a counter-notice after the report was resolved as removed, and reopens it" do
    report.update!(state: "resolved", outcome: "removed", resolved_at: 1.day.ago, outcome_notified_at: 1.day.ago)

    expect(call).to be_success
    expect(report.reload).to have_attributes(state: "counter_noticed", outcome: nil, resolved_at: nil)
    expect(PiracyReports::ResolveService.new(report:, outcome: "restored").call).to be_success
  end

  it "refuses a counter-notice after an outcome that cannot change" do
    report.update!(state: "resolved", outcome: "withdrawn", outcome_reason: "Licensed.", resolved_at: 1.day.ago)

    expect(call.errors).to eq(["The report has no notice out with a host"])
  end

  it "accepts the host's local date the day before the UTC send date" do
    report.update!(sent_at: Time.utc(2026, 10, 8, 2))

    travel_to(Time.utc(2026, 10, 8, 12)) { expect(call(received_on: "2026-10-07")).to be_success }
  end

  it "refuses a body that fits the character limit but not the column's bytes" do
    expect(call(body: "😀" * 17_000).errors).to eq(["body is too long"])
  end

  it "finishes the forward on a retry when the seller email failed to queue" do
    allow(PiracyReportMailer).to receive(:counter_notice_received).and_raise(Redis::CannotConnectError)
    expect { call }.to raise_error(Redis::CannotConnectError)
    expect(report.reload).to have_attributes(state: "counter_noticed", counter_notice_forwarded_at: nil)

    allow(PiracyReportMailer).to receive(:counter_notice_received).and_call_original
    expect { expect(call).to be_success }.to have_enqueued_mail(PiracyReportMailer, :counter_notice_received)
    expect(report.reload.counter_notice_forwarded_at).to be_present
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
