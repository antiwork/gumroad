# frozen_string_literal: true

require "spec_helper"

describe PiracyReports::SendService do
  let(:report) { create(:piracy_report, :signed, recipient_email: "copyright@example.com") }
  let(:registry) do
    { "example.net" => PiracyReports::RecipientRegistry::Entry.new(name: "Example Net Inc.", email: "copyright@example.com", source_url: "https://dmca.copyright.gov/osp/example") }
  end

  before do
    allow(PiracyReports::RecipientRegistry).to receive(:entries).and_return(registry)
    Feature.activate(:piracy_reports_sending)
  end

  def call(on: report)
    described_class.new(report: on).call
  end

  it "sends the signed text to the registry contact from support@, with the seller in CC and a per-report Reply-To" do
    expect { expect(call).to be_success }
      .to change { ActionMailer::Base.deliveries.count }.by(1)
      .and have_enqueued_mail(PiracyReportMailer, :notice_sent).with(report.id)

    report.reload
    expect(report).to have_attributes(state: "sent", sent_to_email: "copyright@example.com", last_contact_email: report.seller.email)
    expect(report.reply_token).to match(/\A[a-z0-9]{16}\z/)
    expect(report.sent_at).to be_present
    expect(report.sent_message_id).to be_present

    mail = ActionMailer::Base.deliveries.last
    expect(mail.to).to eq(["copyright@example.com"])
    expect(mail.cc).to eq([report.seller.email])
    expect(mail.from).to eq([ApplicationMailer::SUPPORT_EMAIL])
    expect(mail.reply_to).to eq(["support+piracy-#{report.reply_token}@#{DEFAULT_EMAIL_DOMAIN}"])
    expect(mail.body.decoded).to eq("Notice text")
  end

  it "sends nothing while the sending flag is off" do
    Feature.deactivate(:piracy_reports_sending)

    expect(call.errors).to eq(["Sending is turned off"])
    expect(report.reload.state).to eq("signed")
  end

  it "refuses a notice whose text no longer matches the signed digest" do
    report.update_columns(notice_text: "Notice text, edited after signing")

    expect(call.errors).to eq(["The notice changed after it was signed"])
    expect(report.reload.state).to eq("signed")
  end

  it "refuses a signature taken under an older confirmation text" do
    report.update_columns(signature_statement_version: "2026-01-01")

    expect(call.errors).to eq(["The signature is not under the current confirmations"])
    expect(report.reload.state).to eq("signed")
  end

  it "refuses when the host's registry contact changed after screening" do
    registry["example.net"] = registry["example.net"].with(email: "dmca@example.com")

    expect(call.errors).to eq(["The host's registry contact changed after screening"])
    expect(report.reload.state).to eq("signed")
  end

  it "never sends the same report twice, even from a copy loaded before the first send" do
    stale_copy = PiracyReport.find(report.id)
    call

    expect { expect(call(on: stale_copy).errors).to eq(["The report is not signed"]) }.not_to change { ActionMailer::Base.deliveries.count }
  end

  it "records the provider's rejection when the mailer's SMTP handler swallows it" do
    allow_any_instance_of(Mail::Message).to receive(:deliver).and_raise(Net::SMTPFatalError.new("550 mailbox unavailable"))

    expect(call.errors).to eq(["The notice could not be sent: 550 mailbox unavailable"])
    expect(report.reload.delivery_failed_at).to be_present
  end

  it "keeps a delivered send successful when recording the message id fails" do
    allow_any_instance_of(PiracyReport).to receive(:update!).and_wrap_original do |original, *args|
      raise ActiveRecord::StatementInvalid, "lost connection" if args.first.key?(:sent_message_id)

      original.call(*args)
    end

    expect(call).to be_success
    expect(report.reload).to have_attributes(state: "sent", delivery_failed_at: nil)
  end

  it "refuses when the registry entry for the host was removed" do
    registry.clear

    expect(call.errors).to eq(["The host's registry contact changed after screening"])
    expect(report.reload.state).to eq("signed")
  end

  it "refuses when the registry contact's name changed" do
    registry["example.net"] = registry["example.net"].with(name: "Another Host LLC")

    expect(call.errors).to eq(["The host's registry contact changed after screening"])
    expect(report.reload.state).to eq("signed")
  end

  it "keeps a delivered send successful when the seller's confirmation fails to queue" do
    allow(PiracyReportMailer).to receive(:notice_sent).and_raise(Redis::CannotConnectError)

    expect(call).to be_success
    expect(report.reload).to have_attributes(state: "sent", delivery_failed_at: nil)
  end

  it "explains why a signed report is not going out" do
    registry["example.net"] = registry["example.net"].with(email: "dmca@example.com")

    expect(described_class.new(report:).blocking_reason).to eq("The host's registry contact changed after screening")
  end

  it "keeps the report sent and records the failure when delivery raises, so it is not retried" do
    allow(PiracyReportMailer).to receive(:notice).and_raise(Net::SMTPFatalError.new("550 rejected"))

    expect(call.errors.first).to start_with("The notice could not be sent")
    expect(report.reload).to have_attributes(state: "sent")
    expect(report.delivery_failed_at).to be_present
  end
end
