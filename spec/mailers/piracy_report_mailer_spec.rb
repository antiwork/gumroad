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

    it "sends nothing once the report has been closed" do
      # Proves deliveries are counted at all, so the closed-report assertion below is not vacuous.
      expect { described_class.signature_request(report.id).deliver_now }
        .to change { ActionMailer::Base.deliveries.count }.by(1)

      report.cancel!

      expect { described_class.signature_request(report.id).deliver_now }
        .not_to change { ActionMailer::Base.deliveries.count }
    end
  end

  describe "notice" do
    let(:report) do
      create(:piracy_report, :signed, state: "sent", reply_token: "abc123", sent_to_email: "copyright@example.com", last_contact_email: "seller@example.com")
    end

    subject(:mail) { described_class.notice(report.id) }

    it "sends the signed text as plain text from support@, to the host, with the seller in CC and the report's Reply-To" do
      expect(mail.from).to eq([ApplicationMailer::SUPPORT_EMAIL])
      expect(mail.to).to eq(["copyright@example.com"])
      expect(mail.cc).to eq(["seller@example.com"])
      expect(mail.reply_to).to eq(["support+piracy-abc123@#{DEFAULT_EMAIL_DOMAIN}"])
      expect(mail.content_type).to start_with("text/plain")
      expect(mail.body.decoded).to eq("Notice text")
    end
  end

  describe "notice_sent" do
    let(:report) { create(:piracy_report, :signed, state: "sent", sent_at: Time.utc(2026, 10, 8), last_contact_email: "seller@example.com") }

    subject(:mail) { described_class.notice_sent(report.id) }

    it "tells the seller where and when the notice went, with a link to the report" do
      expect(mail.to).to eq(["seller@example.com"])
      expect(mail.subject).to eq("We sent your takedown notice for #{report.product.name}")
      expect(mail.body.encoded).to include("Example Net Inc.")
      expect(mail.body.encoded).to include(piracy_report_url(report.external_id))
    end
  end

  describe "counter_notice_received" do
    let(:report) do
      create(:piracy_report, :signed, state: "counter_noticed", last_contact_email: "seller@example.com",
                                      counter_notice_body: "I own a license for this course.", counter_notice_received_on: Date.new(2026, 10, 7))
    end

    it "forwards the full counter-notice with the date the host received it and the restoration rule" do
      mail = described_class.counter_notice_received(report.id)

      expect(mail.to).to eq(["seller@example.com"])
      expect(mail.body.encoded).to include("I own a license for this course.", "October 7, 2026", "10 to 14 business days")
    end
  end

  describe "resolved" do
    it "tells the seller the outcome" do
      report = create(:piracy_report, :signed, state: "resolved", outcome: "removed", last_contact_email: "seller@example.com")
      # A counter-notice can reopen the report before the queued email runs.
      report.update!(state: "counter_noticed", outcome: nil)

      mail = described_class.resolved(report.id, "removed")

      expect(mail.subject).to eq("Your takedown notice for #{report.product.name} is closed")
      expect(mail.body.encoded).to include("The site removed the page")
    end
  end
end
