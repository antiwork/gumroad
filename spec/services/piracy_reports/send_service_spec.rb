# frozen_string_literal: true

require "spec_helper"

describe PiracyReports::SendService do
  before { Feature.activate(described_class::FLAG) }

  def send_report(report)
    described_class.new(report:).call
  end

  it "sends the signed text to the host's agent, with the seller in CC and the report's own reply-to" do
    report = create(:piracy_report, :signed)

    result = nil
    expect { result = send_report(report) }.to change { ActionMailer::Base.deliveries.count }.by(1)

    expect(result).to be_success
    mail = ActionMailer::Base.deliveries.last
    expect(mail.to).to eq(["copyright@example.com"])
    expect(mail.cc).to eq([report.seller.email])
    expect(mail.from).to eq([ApplicationMailer::SUPPORT_EMAIL])
    expect(mail.reply_to).to eq([report.reload.reply_to_address])
    # The host gets the text the seller signed, byte for byte.
    expect(mail.body.to_s).to eq(report.notice_text)
  end

  it "records the dispatch on the report" do
    report = create(:piracy_report, :signed)

    expect(send_report(report)).to be_success

    report.reload
    expect(report).to be_sent
    expect(report.sent_at).to be_present
    expect(report.sent_to_email).to eq("copyright@example.com")
    expect(report.final_notice_digest).to eq(report.notice_digest)
    expect(report.sent_message_id).to be_present
    expect(report.delivery_status).to eq("sent")
  end

  it "does not send a second notice" do
    report = create(:piracy_report, :signed)
    send_report(report)

    expect { expect(send_report(report.reload)).not_to be_success }.not_to change { ActionMailer::Base.deliveries.count }
    expect(report.reload).to be_sent
  end

  it "refuses to send while the kill switch is off" do
    Feature.deactivate(described_class::FLAG)
    report = create(:piracy_report, :signed)

    expect { expect(send_report(report)).not_to be_success }.not_to change { ActionMailer::Base.deliveries.count }
    expect(report.reload).to be_signed
  end

  it "refuses text that changed after it was signed" do
    report = create(:piracy_report, :signed)
    report.update_columns(notice_text: "#{report.notice_text}\nOne more page.\n")

    result = nil
    expect { result = send_report(report) }.not_to change { ActionMailer::Base.deliveries.count }

    expect(result.errors).to include("The notice changed after it was signed")
    expect(report.reload).to be_signed
  end

  it "refuses a report that was never signed" do
    report = create(:piracy_report, :awaiting_signature)

    expect { expect(send_report(report)).not_to be_success }.not_to change { ActionMailer::Base.deliveries.count }
    expect(report.reload).to be_awaiting_signature
  end

  it "refuses a report with no recipient" do
    report = create(:piracy_report, :signed, recipient_email: nil)

    expect { expect(send_report(report)).not_to be_success }.not_to change { ActionMailer::Base.deliveries.count }
    expect(report.reload).to be_signed
  end

  it "keeps the report sent but records the failure when the mail cannot go out" do
    report = create(:piracy_report, :signed)
    allow(PiracyReportMailer).to receive(:takedown_notice).and_raise(StandardError, "smtp down")

    result = send_report(report)

    expect(result).not_to be_success
    expect(report.reload).to be_sent
    expect(report.delivery_status).to eq("failed")
  end
end
