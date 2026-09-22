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

  describe ".enqueue_buyer_download_stamp!" do
    let(:seller) { create(:named_seller) }
    let(:product) { create(:product, user: seller) }
    let(:purchase) { create(:purchase, link: product, seller:) }

    before { purchase.create_url_redirect! }

    it "schedules a follower when an earlier enqueue still owns the cache key" do
      Rails.cache.write(described_class.cache_key_for_purchase(purchase.id), "existing-jid")

      described_class.enqueue_buyer_download_stamp!(purchase.id)

      expect(StampPdfForPurchaseJob.jobs).to be_empty
      expect(DeliverFilesReadyNotificationJob).to have_enqueued_sidekiq_job(purchase.id)
      expect(described_class.buyer_notification_requested?(purchase.id)).to be(true)
    end

    it "schedules a follower when the stamp enqueue is dropped by the purchase lock" do
      allow(StampPdfForPurchaseJob).to receive_message_chain(:set, :perform_async).and_return(nil)

      described_class.enqueue_buyer_download_stamp!(purchase.id)

      expect(DeliverFilesReadyNotificationJob).to have_enqueued_sidekiq_job(purchase.id)
      expect(described_class.buyer_notification_requested?(purchase.id)).to be(true)
    end
  end

  describe ".deliver_files_ready_notification!" do
    let(:seller) { create(:named_seller) }
    let(:product) { create(:product, user: seller) }
    let(:purchase) { create(:purchase, link: product, seller:) }

    before { purchase.create_url_redirect! }

    it "clears the request it claimed" do
      described_class.request_buyer_notification!(purchase.id)

      expect(described_class.deliver_files_ready_notification!(purchase.id)).to be(true)
      expect(described_class.buyer_notification_requested?(purchase.id)).to be(false)
    end

    # The winner claims the request, then a click clears the enqueued bit and records its
    # own. Clearing the request after that would erase it, and the follower would send nothing.
    it "keeps a request a click records after the claim" do
      described_class.request_buyer_notification!(purchase.id)
      allow(CustomerMailer).to receive(:files_ready_for_download).and_wrap_original do |original, purchase_id|
        described_class.request_buyer_notification!(purchase_id)
        original.call(purchase_id)
      end

      expect(described_class.deliver_files_ready_notification!(purchase.id)).to be(true)
      expect(described_class.buyer_notification_requested?(purchase.id)).to be(true)

      expect do
        DeliverFilesReadyNotificationJob.new.perform(purchase.id)
      end.to have_enqueued_mail(CustomerMailer, :files_ready_for_download).with(purchase.id)
    end
  end
end
