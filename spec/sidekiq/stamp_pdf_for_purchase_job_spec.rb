# frozen_string_literal: true

require "spec_helper"

describe StampPdfForPurchaseJob do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller) }
  let(:purchase) { create(:purchase, link: product, seller: seller) }

  before do
    allow(PdfStampingService).to receive(:stamp_for_purchase!)
  end

  it "performs the job" do
    described_class.new.perform(purchase.id)
    expect(PdfStampingService).to have_received(:stamp_for_purchase!).with(purchase)
  end

  it "enqueues files ready email when notify flag is true" do
    expect do
      purchase.create_url_redirect!
      described_class.new.perform(purchase.id, true)
    end.to have_enqueued_mail(CustomerMailer, :files_ready_for_download).with(purchase.id)
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
