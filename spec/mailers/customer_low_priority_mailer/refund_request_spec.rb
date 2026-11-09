# frozen_string_literal: true

require "spec_helper"

describe CustomerLowPriorityMailer do
  let(:seller) { create(:user, name: "Jane") }
  let(:purchase) { create(:purchase, link: create(:product, user: seller, name: "Brush pack")) }
  let(:refund_request) { create(:purchase_refund_request, purchase:) }

  before do
    # Friday, so the deadline is Tuesday, November 10; the whole example renders at this time.
    travel_to(Time.utc(2026, 11, 6, 12))
    Feature.activate_user(:buyer_refund_requests, seller)
  end

  describe "#refund_request_received" do
    it "tells the buyer who decides, by when, and links to the status page" do
      mail = described_class.refund_request_received(refund_request.id)

      expect(mail.to).to eq([refund_request.email])
      expect(mail.reply_to).to eq([seller.support_or_form_email])
      expect(mail.subject).to eq("Your refund request for Brush pack was sent to Jane")
      body = mail.body.decoded.squish
      expect(body).to include("Jane decides whether to refund you. If you aren't refunded by Tuesday, November 10, Gumroad support will review your request.")
      expect(body).to include("/purchases/")
      expect(body).to include("/refund_request")
    end
  end

  describe "#refund_request_escalated" do
    it "tells the buyer support has the request and sends replies to support" do
      refund_request.update!(escalated_at: Time.current)
      mail = described_class.refund_request_escalated(refund_request.id)

      expect(mail.to).to eq([refund_request.email])
      expect(mail.reply_to).to eq([ApplicationMailer::SUPPORT_EMAIL])
      expect(mail.subject).to eq("Gumroad support is reviewing your refund request for Brush pack")
      expect(mail.body.decoded.squish).to include("Jane hasn't refunded your purchase of Brush pack")
    end
  end

  it "does not send when the request is gone, or no longer has the status the email describes" do
    expect(described_class.refund_request_received(nil).message).to be_a(ActionMailer::Base::NullMail)
    expect(described_class.refund_request_escalated(refund_request.id).message).to be_a(ActionMailer::Base::NullMail)

    purchase.update!(stripe_refunded: true)
    expect(described_class.refund_request_received(refund_request.id).message).to be_a(ActionMailer::Base::NullMail)
  end

  it "does not send a confirmation whose deadline has passed" do
    refund_request
    travel_to(Time.utc(2026, 11, 11, 12))

    expect(described_class.refund_request_received(refund_request.id).message).to be_a(ActionMailer::Base::NullMail)
  end
end
