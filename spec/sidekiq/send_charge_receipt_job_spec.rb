# frozen_string_literal: true

require "spec_helper"

describe SendChargeReceiptJob do
  let(:seller) { create(:named_seller) }
  let(:product_one) { create(:product, user: seller, name: "Product One") }
  let(:purchase_one) { create(:purchase, link: product_one, seller: seller) }
  let(:product_two) { create(:product, user: seller, name: "Product Two") }
  let(:purchase_two) { create(:purchase, link: product_two, seller: seller) }
  let(:charge) { create(:charge, purchases: [purchase_one, purchase_two], seller: seller) }
  let(:order) { charge.order }

  before do
    charge.order.purchases << purchase_one
    charge.order.purchases << purchase_two
    allow(PdfStampingService).to receive(:stamp_for_purchase!)
    allow(CustomerMailer).to receive_message_chain(:receipt, :deliver_now)
  end

  context "with all purchases ready" do
    it "delivers the email and updates the charge without stamping" do
      described_class.new.perform(charge.id)

      expect(PdfStampingService).not_to have_received(:stamp_for_purchase!)
      expect(CustomerMailer).to have_received(:receipt).with(nil, charge.id)
      expect(charge.reload.receipt_sent?).to be(true)
    end
  end

  context "when the charge receipt has already been sent" do
    before do
      charge.update!(receipt_sent: true)
    end

    it "does nothing" do
      described_class.new.perform(charge.id)
      expect(PdfStampingService).not_to have_received(:stamp_for_purchase!)
      expect(CustomerMailer).not_to have_received(:receipt)
    end
  end

  context "when a purchase requires stamping" do
    before do
      allow_any_instance_of(Charge).to receive(:purchases_requiring_stamping).and_return([purchase_one])
    end

    it "stamps the PDFs and delivers the email" do
      described_class.new.perform(charge.id)

      expect(PdfStampingService).to have_received(:stamp_for_purchase!).exactly(:once)
      expect(PdfStampingService).to have_received(:stamp_for_purchase!).with(purchase_one)
      expect(CustomerMailer).to have_received(:receipt).with(nil, charge.id)
      expect(charge.reload.receipt_sent?).to be(true)
    end

    context "when stamping fails" do
      before do
        allow(PdfStampingService).to receive(:stamp_for_purchase!).and_raise(PdfStampingService::Error)
      end

      it "doesn't deliver the email and raises an error" do
        expect(CustomerMailer).not_to receive(:receipt)
        expect { described_class.new.perform(charge.id) }.to raise_error(PdfStampingService::Error)
        expect(charge.reload.receipt_sent?).to be(false)
      end
    end
  end
end
