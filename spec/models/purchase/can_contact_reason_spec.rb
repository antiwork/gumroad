# frozen_string_literal: true

require "spec_helper"

describe "Purchase can_contact_reason" do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }
  let!(:purchase) { create(:purchase, link: product, seller:, email: "buyer@example.com") }

  describe "#unsubscribe_buyer" do
    it "records a buyer unsubscribe by default" do
      purchase.unsubscribe_buyer

      purchase.reload
      expect(purchase.can_contact).to be(false)
      expect(purchase.can_contact_reason).to eq(Purchase::CAN_CONTACT_REASON_BUYER_UNSUBSCRIBE)
    end

    it "records the caller's reason on every row it suppresses" do
      sibling = create(:purchase, link: product, seller:, email: purchase.email)

      purchase.unsubscribe_buyer(reason: Purchase::CAN_CONTACT_REASON_SPAM_REPORT)

      [purchase, sibling].each do |row|
        expect(row.reload.can_contact_reason).to eq(Purchase::CAN_CONTACT_REASON_SPAM_REPORT)
      end
    end

    it "records the reason even when the row fails today's validations" do
      purchase.update_columns(street_address: nil, country: nil, zip_code: nil)
      allow_any_instance_of(Purchase).to receive(:valid?).and_return(false)

      purchase.unsubscribe_buyer

      expect(purchase.reload.can_contact_reason).to eq(Purchase::CAN_CONTACT_REASON_BUYER_UNSUBSCRIBE)
    end

    it "leaves json_data's other attributes intact" do
      purchase.update!(locale: "fr")

      purchase.unsubscribe_buyer

      expect(purchase.reload.locale).to eq("fr")
      expect(purchase.can_contact_reason).to eq(Purchase::CAN_CONTACT_REASON_BUYER_UNSUBSCRIBE)
    end
  end

  describe "a new row born uncontactable" do
    it "is marked inherited, not as a buyer action" do
      purchase.unsubscribe_buyer

      later = create(:purchase, link: product, seller:, email: purchase.email)

      expect(later.can_contact).to be(false)
      expect(later.can_contact_reason).to eq(Purchase::CAN_CONTACT_REASON_INHERITED)
    end

    it "leaves the reason unset when the buyer never unsubscribed" do
      fresh = create(:purchase, link: product, seller:, email: "someone-else@example.com")

      expect(fresh.can_contact).to be(true)
      expect(fresh.can_contact_reason).to be_nil
    end
  end

  describe "spam reports" do
    it "records a spam report from a receipt complaint" do
      email_event_info = double(
        type: EmailEventInfo::EVENT_COMPLAINED,
        email_provider: MailerInfo::EMAIL_PROVIDER_SENDGRID,
        purchase_id: purchase.id,
        charge_id: nil,
        mailer_method: "receipt",
      )

      HandleEmailEventInfo::ForReceiptEmail.perform(email_event_info)

      expect(purchase.reload.can_contact_reason).to eq(Purchase::CAN_CONTACT_REASON_SPAM_REPORT)
    end
  end
end
