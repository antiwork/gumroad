# frozen_string_literal: true

require "spec_helper"

describe HandleEmailEventInfo::ForPiracyNotice do
  let(:report) { create(:piracy_report, :signed, state: "sent", sent_at: 2.hours.ago, sent_to_email: "copyright@example.com", last_contact_email: "seller@example.com") }

  def sendgrid_event(event, email:)
    HandleSendgridEventJob.new.perform(
      "_json" => [{
        "event" => EmailEventInfo::EVENTS[event][MailerInfo::EMAIL_PROVIDER_SENDGRID],
        "email" => email,
        "timestamp" => Time.utc(2026, 10, 8, 12).to_i,
        "mailer_class" => "PiracyReportMailer",
        "mailer_method" => "notice",
        "mailer_args" => "[#{report.id}]"
      }]
    )
  end

  def resend_event(event, report_id:)
    HandleResendEventJob.new.perform(
      "type" => EmailEventInfo::EVENTS[event][MailerInfo::EMAIL_PROVIDER_RESEND],
      "data" => {
        "created_at" => "2026-10-08 12:00:00+00",
        "to" => ["copyright@example.com"],
        "headers" => [
          { "name" => MailerInfo.header_name(:mailer_class), "value" => MailerInfo.encrypt("PiracyReportMailer") },
          { "name" => MailerInfo.header_name(:mailer_method), "value" => MailerInfo.encrypt("notice") },
          { "name" => MailerInfo.header_name(:mailer_args), "value" => MailerInfo.encrypt("[#{report_id}]") }
        ]
      }
    )
  end

  it "records delivery and bounces reported by Resend" do
    bounced = create(:piracy_report, :signed, state: "sent", sent_at: 2.hours.ago, sent_to_email: "copyright@example.com")

    resend_event(:delivered, report_id: report.id)
    resend_event(:bounced, report_id: bounced.id)

    expect(report.reload.delivered_at).to eq(Time.utc(2026, 10, 8, 12))
    expect(bounced.reload.delivery_failed_at).to eq(Time.utc(2026, 10, 8, 12))
  end

  it "records delivery to the host" do
    sendgrid_event(:delivered, email: "copyright@example.com")

    expect(report.reload.delivered_at).to eq(Time.utc(2026, 10, 8, 12))
  end

  it "records a bounce from the host, which puts the report in the person queue" do
    sendgrid_event(:bounced, email: "copyright@example.com")

    expect(report.reload.delivery_failed_at).to eq(Time.utc(2026, 10, 8, 12))
    expect(PiracyReport.delivery_failed).to contain_exactly(report)
  end

  it "drops a recorded failure from the person queue once the host's copy is delivered" do
    report.update!(delivery_failed_at: 1.hour.ago)

    sendgrid_event(:delivered, email: "copyright@example.com")

    expect(PiracyReport.delivery_failed).to be_empty
  end

  it "ignores events for the seller's CC copy" do
    sendgrid_event(:bounced, email: "seller@example.com")
    sendgrid_event(:delivered, email: "seller@example.com")

    expect(report.reload).to have_attributes(delivered_at: nil, delivery_failed_at: nil)
  end

  it "keeps the first delivery time, and a later bounce does not remove a delivery" do
    sendgrid_event(:delivered, email: "copyright@example.com")
    report.update!(delivered_at: 3.hours.ago)
    sendgrid_event(:delivered, email: "copyright@example.com")
    sendgrid_event(:bounced, email: "copyright@example.com")

    expect(report.reload.delivered_at).to be_within(1.second).of(3.hours.ago)
    expect(PiracyReport.delivery_failed).to be_empty
  end

  it "ignores an event for an unknown report" do
    expect { resend_event(:delivered, report_id: 0) }.not_to raise_error
  end
end
