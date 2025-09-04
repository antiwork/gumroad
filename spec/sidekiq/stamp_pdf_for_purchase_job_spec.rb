# frozen_string_literal: true

require "spec_helper"

describe StampPdfForPurchaseJob do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller) }
  let(:purchase) { create(:test_purchase, link: product, seller: seller) }

  before do
    allow(PdfStampingService).to receive(:stamp_for_purchase!)
  end

  it "performs the job" do
    described_class.new.perform(purchase.id)
    expect(PdfStampingService).to have_received(:stamp_for_purchase!).with(purchase)
  end

  it "sends a stamped pdf ready email when stamped pdfs exist" do
    purchase.create_url_redirect!
    create(:stamped_pdf, url_redirect: purchase.url_redirect, product_file: create(:pdf_product_file, link: product))

    mail_double = double(deliver_now: true)
    expect(CustomerMailer).to receive(:stamped_pdf_ready).with(purchase.id).and_return(mail_double)

    described_class.new.perform(purchase.id)
  end

  context "when stamping the PDFs fails with a known error" do
    before do
      allow(PdfStampingService).to receive(:stamp_for_purchase!).and_raise(PdfStampingService::Error)
    end

    it "logs and doesn't raise an error" do
      expect(Rails.logger).to receive(:error).with(/Failed stamping for purchase #{purchase.id}:/)
      expect { described_class.new.perform(purchase.id) }.not_to raise_error
    end
  end

  context "when stamping the PDFs fails with an unknown error" do
    before do
      allow(PdfStampingService).to receive(:stamp_for_purchase!).and_raise(StandardError)
    end

    it "raise an error" do
      expect { described_class.new.perform(purchase.id) }.to raise_error(StandardError)
    end
  end
end
