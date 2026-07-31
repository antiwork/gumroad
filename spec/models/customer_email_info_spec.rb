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

  describe ".build_for_charge" do
    let(:purchase) { create(:purchase) }
    let(:charge) { create(:charge, purchases: [purchase]) }

    it "builds a new row even when one already exists for the charge" do
      existing = create(
        :customer_email_info,
        purchase_id: nil,
        email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD,
        email_info_charge_attributes: { charge_id: charge.id }
      )

      email_info = CustomerEmailInfo.build_for_charge(
        charge_id: charge.id,
        email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD
      )

      expect(email_info.persisted?).to be(false)
      expect(email_info).not_to eq(existing)
      expect(email_info.charge_id).to eq(charge.id)
    end
  end

  describe ".build_for_purchase" do
    let(:purchase) { create(:purchase) }

    it "builds a new row even when one already exists for the purchase" do
      existing = create(:customer_email_info, email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD, purchase:)

      email_info = CustomerEmailInfo.build_for_purchase(
        purchase_id: purchase.id,
        email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD
      )

      expect(email_info.persisted?).to be(false)
      expect(email_info).not_to eq(existing)
      expect(email_info.purchase_id).to eq(purchase.id)
    end
  end

  # gumroad-private#1635: a seller reported "the receipt took five days to
  # arrive". It had not. He resent on day five, and the resend overwrote the
  # original send's row, so the only surviving record claimed the first send
  # happened then.
  describe "a resend after the original send was delivered" do
    let(:purchase) { create(:purchase) }

    it "keeps the original send's delivery evidence on its own row" do
      original = CustomerEmailInfo.build_for_purchase(
        purchase_id: purchase.id,
        email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD
      )
      original.mark_sent!
      original.mark_delivered!(Time.current)
      original_sent_at = original.reload.sent_at
      original_delivered_at = original.reload.delivered_at

      travel_to 5.days.from_now do
        resend = CustomerEmailInfo.build_for_purchase(
          purchase_id: purchase.id,
          email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD
        )
        resend.mark_sent!

        expect(resend.id).not_to eq(original.id)
        expect(original.reload.sent_at).to be_within(1.second).of(original_sent_at)
        expect(original.reload.delivered_at).to be_within(1.second).of(original_delivered_at)
        expect(original.reload.state).to eq("delivered")

        # Readers take the newest row, so the resend is what a delivery event
        # and the seller-facing "Receipt" row both resolve to.
        expect(purchase.reload.receipt_email_info).to eq(resend)
        expect(
          CustomerEmailInfo.find_or_initialize_for_purchase(
            purchase_id: purchase.id,
            email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD
          )
        ).to eq(resend)
      end
    end

    it "resolves the newest row per charge, so a delivery event lands on the latest send" do
      charge = create(:charge, purchases: [purchase])

      first = CustomerEmailInfo.build_for_charge(
        charge_id: charge.id,
        email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD
      )
      first.mark_sent!

      resend = CustomerEmailInfo.build_for_charge(
        charge_id: charge.id,
        email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD
      )
      resend.mark_sent!

      # Pins ordering on the charge side: `.first` here would route every event
      # onto the original row and re-create the overwrite this fix removes.
      expect(charge.reload.receipt_email_info).to eq(resend)
      expect(
        CustomerEmailInfo.find_or_initialize_for_charge(
          charge_id: charge.id,
          email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD
        )
      ).to eq(resend)

      # ...while the full history stays oldest-first for evidence readers.
      expect(charge.reload.receipt_email_infos.map(&:id)).to eq([first.id, resend.id])
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
