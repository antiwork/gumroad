# frozen_string_literal: true

require "test_helper"

class PdfStampingServiceTest < ActiveSupport::TestCase
  self.described_class = PdfStampingService



  context_ PdfStampingService do
  context_ ".can_stamp_file?" do
      let(:product_file) { instance_double("ProductFile") }

      before do
        allow(PdfStampingService::Stamp).to receive(:can_stamp_file?).and_return(true)
      end

  test "calls can_stamp_file? on PdfStampingService::Stamp with the product file" do
        described_class.can_stamp_file?(product_file: product_file)
        expect(PdfStampingService::Stamp).to have_received(:can_stamp_file?).with(product_file: product_file)
      end

  test "returns the result from PdfStampingService::Stamp.can_stamp_file?" do
        result = described_class.can_stamp_file?(product_file: product_file)
        expect(result).to be true
      end
    end

  context_ ".stamp_for_purchase!" do
      let(:purchase) { instance_double("Purchase") }

      before do
        allow(PdfStampingService::StampForPurchase).to receive(:perform!).and_return(true)
      end

  test "calls perform! on PdfStampingService::StampForPurchase with the purchase" do
        described_class.stamp_for_purchase!(purchase)
        expect(PdfStampingService::StampForPurchase).to have_received(:perform!).with(purchase)
      end

  test "returns the result from PdfStampingService::StampForPurchase.perform!" do
        result = described_class.stamp_for_purchase!(purchase)
        expect(result).to be true
      end
    end

  context_ ".cache_key_for_purchase" do
  test "returns the correct cache key format for a given purchase ID" do
        purchase_id = 12345
        expected_key = "stamp_pdf_for_purchase_job_12345"

        result = described_class.cache_key_for_purchase(purchase_id)

        expect(result).to eq(expected_key)
      end
    end
  end
end
