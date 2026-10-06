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
end
