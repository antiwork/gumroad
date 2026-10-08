# frozen_string_literal: true

require "spec_helper"

describe PiracyReports::ResolveService do
  let(:report) { create(:piracy_report, :signed, state: "sent", sent_at: 3.days.ago, last_contact_email: "seller@example.com") }

  it "records the outcome and tells the seller" do
    expect { expect(described_class.new(report:, outcome: "removed").call).to be_success }
      .to have_enqueued_mail(PiracyReportMailer, :resolved).with(report.id, "removed")

    expect(report.reload).to have_attributes(state: "resolved", outcome: "removed")
    expect(report.resolved_at).to be_present
  end

  it "resolves a report that got a counter-notice" do
    report.update!(state: "counter_noticed")

    expect(described_class.new(report:, outcome: "restored").call).to be_success
    expect(report.reload.outcome).to eq("restored")
  end

  it "needs a reason to record a withdrawal, and keeps it" do
    expect(described_class.new(report:, outcome: "withdrawn").call.errors).to eq(["a withdrawn report needs a reason"])

    described_class.new(report:, outcome: "withdrawn", reason: "The seller licensed the site after filing.").call
    expect(report.reload).to have_attributes(outcome: "withdrawn", outcome_reason: "The seller licensed the site after filing.")
  end

  it "accepts restored only after a recorded counter-notice" do
    expect(described_class.new(report:, outcome: "restored").call.errors).to eq(["restored needs a recorded counter-notice"])
    expect(report.reload.state).to eq("sent")
  end

  it "sends the outcome email on a retry when it failed to queue, and refuses a second outcome after that" do
    allow(PiracyReportMailer).to receive(:resolved).and_raise(Redis::CannotConnectError)
    expect { described_class.new(report:, outcome: "removed").call }.to raise_error(Redis::CannotConnectError)
    expect(report.reload).to have_attributes(state: "resolved", outcome_notified_at: nil)

    allow(PiracyReportMailer).to receive(:resolved).and_call_original
    expect { expect(described_class.new(report:, outcome: "removed").call).to be_success }.to have_enqueued_mail(PiracyReportMailer, :resolved)
    expect(report.reload.outcome_notified_at).to be_present

    expect(described_class.new(report:, outcome: "no_response").call.errors).to eq(["The report already has an outcome"])
  end

  it "rejects an unknown outcome and a report that was never sent" do
    expect(described_class.new(report:, outcome: "won").call.errors).to eq(["outcome must be one of removed, no_response, restored, withdrawn"])

    signed = create(:piracy_report, :signed)
    expect(described_class.new(report: signed, outcome: "removed").call.errors).to eq(["The report has no notice out with a host"])
    expect(signed.reload.state).to eq("signed")
  end
end
