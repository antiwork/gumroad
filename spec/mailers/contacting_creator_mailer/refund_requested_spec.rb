# frozen_string_literal: true

require "spec_helper"

describe ContactingCreatorMailer do
  describe "#refund_requested" do
    let(:purchase) { create(:purchase) }
    let(:refund_request) { create(:purchase_refund_request, purchase:, message: "The files were corrupted.") }

    before { Feature.activate_user(:buyer_refund_requests, purchase.seller) }

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

    it "tells a seller emailed after escalation that support already has the request" do
      refund_request.update_columns(state: "escalated", open_key: nil, created_at: 5.days.ago)

      body = described_class.refund_requested(refund_request.id).body.encoded

      expect(body).to include("Gumroad support is already looking at it")
      expect(body).not_to include("Please respond within")
    end

    it "does not ask for a reply within the deadline once the deadline has passed, nor claim support has it yet" do
      refund_request.update_columns(created_at: 5.days.ago)

      body = described_class.refund_requested(refund_request.id).body.encoded

      expect(body).to include("is being passed to Gumroad support")
      expect(body).not_to include("Please respond within")
      expect(body).not_to include("already looking at it")
    end

    it "does not send when the request is gone" do
      mail = described_class.refund_requested(nil)

      expect(mail.message).to be_a(ActionMailer::Base::NullMail)
    end

    it "does not send when the flag was turned off after enqueue" do
      Feature.deactivate_user(:buyer_refund_requests, purchase.seller)

      mail = described_class.refund_requested(refund_request.id)

      expect(mail.message).to be_a(ActionMailer::Base::NullMail)
    end
  end
end
