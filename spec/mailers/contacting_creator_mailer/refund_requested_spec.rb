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
      expect(mail.subject).to eq("Refund requested for #{purchase.link.name} (#{purchase.formatted_display_price})")
      body = mail.body.encoded
      expect(body).to include(purchase.link.name)
      expect(body).to include("The product wasn&#39;t as described")
      expect(body).to include("The files were corrupted.")
      # One-click path to the EXISTING refund action: the seller's sale page.
      expect(body).to include("customers/sale/#{purchase.external_id}")
    end

    it "gives the seller the date to respond by" do
      travel_to(Time.utc(2026, 11, 6, 12)) do # Friday
        body = described_class.refund_requested(refund_request.id).body.encoded

        expect(body).to include("Please respond by Tuesday, November 10.")
      end
    end

    it "still tells the seller after a delayed send, without a date that has passed" do
      # Wednesday; deadline Friday; escalated by the hourly job before this send.
      refund_request.update_columns(created_at: Time.utc(2026, 11, 4, 12), escalated_at: Time.utc(2026, 11, 7, 1))

      body = travel_to(Time.utc(2026, 11, 9, 12)) { described_class.refund_requested(refund_request.id).body.encoded }

      expect(body).to include("This request is past its deadline, so Gumroad support will review it.")
      expect(body).not_to include("Please respond by")
    end

    it "does not send when the purchase was refunded before delivery" do
      refund_request.purchase.update!(stripe_refunded: true)

      expect(described_class.refund_requested(refund_request.id).message).to be_a(ActionMailer::Base::NullMail)
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
