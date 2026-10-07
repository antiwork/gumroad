# frozen_string_literal: true

require "spec_helper"

describe PiracyReportMailer do
  describe "signature_request" do
    let(:report) { create(:piracy_report, :awaiting_signature) }

    subject(:mail) { described_class.signature_request(report.id) }

    it "asks the seller to sign, with a link to the report" do
      expect(mail.to).to eq([report.seller.email])
      expect(mail.subject).to eq("Review and sign the takedown notice for #{report.product.name}")
      expect(mail.body.encoded).to include(piracy_report_url(report.external_id))
      expect(mail.body.encoded).to include(report.product.name)
    end
  end

  describe "takedown_notice" do
    let(:report) { create(:piracy_report, :sent) }

    subject(:mail) { described_class.takedown_notice(report.id) }

    it "sends the signed text to the host's agent, with the seller in CC and the report's reply-to" do
      expect(mail.to).to eq([report.recipient_email])
      expect(mail.cc).to eq([report.seller.email])
      expect(mail.from).to eq([ApplicationMailer::SUPPORT_EMAIL])
      expect(mail.reply_to).to eq([report.reply_to_address])
      # Nothing reflows the notice: the host gets the exact text the seller signed.
      expect(mail.body.to_s).to eq(report.notice_text)
    end
  end

  describe "counter_notice_received" do
    let(:report) { create(:piracy_report, :sent, counter_notice_body: "I own this page.") }

    subject(:mail) { described_class.counter_notice_received(report.id) }

    it "tells the seller the page can come back unless they file a court action" do
      expect(mail.to).to eq([report.seller.email])
      expect(mail.subject).to eq("A site responded to your takedown notice for #{report.product.name}")
      expect(mail.body.encoded).to include("10 to 14 business days")
      expect(mail.body.encoded).to include("I own this page.")
    end
  end
end
