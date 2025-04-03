# frozen_string_literal: true

require "spec_helper"

describe SendPurchaseReceiptJob do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller) }
  let(:purchase) { create(:purchase, link: product, seller: seller) }
  let(:mail_double) { double }

  before do
    allow(mail_double).to receive(:deliver_now)
  end

  context "when the purchase is for a product with stampable PDFs" do
    before do
      allow(PdfStampingService).to receive(:stamp_for_purchase!)
      allow_any_instance_of(Link).to receive(:has_stampable_pdfs?).and_return(true)
    end

    it "stamps the PDFs and delivers the email" do
      expect(CustomerMailer).to receive(:receipt).with(purchase.id).and_return(mail_double)
      described_class.new.perform(purchase.id)

      expect(PdfStampingService).to have_received(:stamp_for_purchase!).with(purchase)
      expect(mail_double).to have_received(:deliver_now)
    end

    context "when stamping the PDF fails" do
      before do
        allow(PdfStampingService).to receive(:stamp_for_purchase!).and_raise(PdfStampingService::Error)
      end

      it "doesn't deliver the email and raises an error" do
        expect(CustomerMailer).not_to receive(:receipt).with(purchase.id)
        expect { described_class.new.perform(purchase.id) }.to raise_error(PdfStampingService::Error)
      end
    end
  end

  context "when the purchase is for a product without stampable PDFs" do
    before do
      allow(PdfStampingService).to receive(:stamp_for_purchase!)
      allow_any_instance_of(Link).to receive(:has_stampable_pdfs?).and_return(false)
    end

    it "delivers the email and doesn't stamp PDFs" do
      expect(CustomerMailer).to receive(:receipt).with(purchase.id).and_return(mail_double)
      described_class.new.perform(purchase.id)

      expect(PdfStampingService).not_to have_received(:stamp_for_purchase!)
      expect(mail_double).to have_received(:deliver_now)
    end
  end

  context "when the purchase is a bundle product purchae" do
    before do
      allow_any_instance_of(Purchase).to receive(:is_bundle_product_purchase?).and_return(true)
    end

    it "doens't deliver email" do
      expect(CustomerMailer).not_to receive(:receipt).with(purchase.id)
      described_class.new.perform(purchase.id)
    end
  end
end
