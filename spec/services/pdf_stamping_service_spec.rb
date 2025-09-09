# frozen_string_literal: true

require "spec_helper"

describe PdfStampingService do
  describe ".can_stamp_file?" do
    let(:product_file) { instance_double("ProductFile") }

    before do
      allow(PdfStampingService::Stamp).to receive(:can_stamp_file?).and_return(true)
    end

    it "calls can_stamp_file? on PdfStampingService::Stamp with the product file" do
      described_class.can_stamp_file?(product_file: product_file)
      expect(PdfStampingService::Stamp).to have_received(:can_stamp_file?).with(product_file: product_file)
    end

    it "returns the result from PdfStampingService::Stamp.can_stamp_file?" do
      result = described_class.can_stamp_file?(product_file: product_file)
      expect(result).to be true
    end
  end

  describe ".stamp_for_purchase!" do
    let(:purchase) { instance_double("Purchase") }

    before do
      allow(PdfStampingService::StampForPurchase).to receive(:perform!).and_return(true)
    end

    it "calls perform! on PdfStampingService::StampForPurchase with the purchase" do
      described_class.stamp_for_purchase!(purchase)
      expect(PdfStampingService::StampForPurchase).to have_received(:perform!).with(purchase)
    end

    it "returns the result from PdfStampingService::StampForPurchase.perform!" do
      result = described_class.stamp_for_purchase!(purchase)
      expect(result).to be true
    end
  end

  describe ".cache_key_for_purchase" do
    it "returns the correct cache key format for a given purchase ID" do
      purchase_id = 12345
      expected_key = "stamp_pdf_for_purchase_job_12345"

      result = described_class.cache_key_for_purchase(purchase_id)

      expect(result).to eq(expected_key)
    end
  end
end
