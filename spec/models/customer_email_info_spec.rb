# frozen_string_literal: true

require "spec_helper"

describe CustomerEmailInfo do
  describe ".find_or_initialize_for_charge" do
    let(:purchase) { create(:purchase) }
    let(:charge) { create(:charge, purchases: [purchase]) }

    context "when the record doesn't exist" do
      it "initializes a new record" do
        email_info = CustomerEmailInfo.find_or_initialize_for_charge(
          charge_id: charge.id,
          email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD
        )
        expect(email_info.persisted?).to be(false)
        expect(email_info.email_name).to eq(SendgridEventInfo::RECEIPT_MAILER_METHOD)
        expect(email_info.charge_id).to eq(charge.id)
        expect(email_info.purchase_id).to be(nil)
      end
    end

    context "when the record exists" do
      let!(:expected_email_info) do
        create(
          :customer_email_info,
          purchase_id: nil,
          email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD,
          email_info_charge_attributes: { charge_id: charge.id }
        )
      end

      it "finds the existing record" do
        email_info = CustomerEmailInfo.find_or_initialize_for_charge(
          charge_id: charge.id,
          email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD
        )
        expect(email_info).to eq(expected_email_info)
        expect(email_info.charge_id).to eq(charge.id)
        expect(email_info.purchase_id).to be(nil)
      end
    end
  end

  describe ".find_or_initialize_for_purchase" do
    let(:purchase) { create(:purchase) }

    context "when the record doesn't exist" do
      it "initializes a new record" do
        email_info = CustomerEmailInfo.find_or_initialize_for_purchase(
          purchase_id: purchase.id,
          email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD
        )
        expect(email_info.persisted?).to be(false)
        expect(email_info.email_name).to eq(SendgridEventInfo::RECEIPT_MAILER_METHOD)
        expect(email_info.purchase_id).to eq(purchase.id)
        expect(email_info.charge_id).to be(nil)
      end
    end

    context "when the record exists" do
      let!(:expected_email_info) do
        create(:customer_email_info, email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD, purchase: purchase)
      end

      it "finds the existing record" do
        email_info = CustomerEmailInfo.find_or_initialize_for_purchase(
          purchase_id: purchase.id,
          email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD
        )
        expect(email_info).to eq(expected_email_info)
        expect(email_info.purchase_id).to eq(purchase.id)
        expect(email_info.charge_id).to be(nil)
      end
    end
  end

  describe "state transitions" do
    it "transitions to sent" do
      email_info = create(:customer_email_info)
      expect(email_info.email_name).to eq "receipt"
      email_info.update_attribute(:delivered_at, Time.current)
      email_info.mark_sent!
      expect(email_info.reload.state).to eq("sent")
      expect(email_info.reload.sent_at).to be_present
      expect(email_info.reload.delivered_at).to be_nil
    end

    it "transitions to delivered" do
      email_info = create(:customer_email_info_sent)
      expect(email_info.sent_at).to be_present
      expect(email_info.delivered_at).to be_nil
      expect(email_info.opened_at).to be_nil
      email_info.mark_delivered!
      expect(email_info.reload.state).to eq("delivered")
      expect(email_info.reload.delivered_at).to be_present
    end

    it "transitions to sent" do
      email_info = create(:customer_email_info_delivered)
      expect(email_info.sent_at).to be_present
      expect(email_info.delivered_at).to be_present
      expect(email_info.opened_at).to be_nil
      email_info.mark_opened!
      expect(email_info.reload.state).to eq("opened")
      expect(email_info.reload.opened_at).to be_present
    end
  end

  describe "#mark_bounced!" do
    it "attempts to unsubscribe the buyer of the purchase" do
      email_info = create(:customer_email_info_delivered)
      expect(email_info.purchase).to receive(:unsubscribe_buyer).and_call_original

      email_info.mark_bounced!
    end
  end
end
