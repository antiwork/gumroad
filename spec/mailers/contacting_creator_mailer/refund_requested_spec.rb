# frozen_string_literal: true

require "spec_helper"

describe ContactingCreatorMailer do
  describe "#refund_requested" do
    let(:purchase) { create(:purchase) }
    let(:refund_request) { create(:purchase_refund_request, purchase:, message: "The files were corrupted.") }

    it "emails the seller with the request and a link to the existing refund action" do
      mail = described_class.refund_requested(refund_request.id)

      expect(mail.to).to eq([purchase.seller.email])
      expect(mail.subject).to eq("A customer has requested a refund")
      body = mail.body.encoded
      expect(body).to include(purchase.link.name)
      expect(body).to include("The product wasn&#39;t as described")
      expect(body).to include("The files were corrupted.")
      # One-click path to the EXISTING refund action: the seller's sale page.
      expect(body).to include("customers/sale/#{purchase.external_id}")
    end

    it "does not send when the request is gone" do
      mail = described_class.refund_requested(nil)

      expect(mail.message).to be_a(ActionMailer::Base::NullMail)
    end
  end
end
