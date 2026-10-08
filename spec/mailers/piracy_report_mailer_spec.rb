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
end
