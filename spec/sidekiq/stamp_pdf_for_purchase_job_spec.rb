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

  it "locks by purchase id across the long and critical queues" do
    long_job = { "class" => described_class.name, "queue" => "long", "args" => [purchase.id] }
    critical_job = { "class" => described_class.name, "queue" => "critical", "args" => [purchase.id, true] }
    long_job["lock_args"] = SidekiqUniqueJobs::LockArgs.call(long_job)
    critical_job["lock_args"] = SidekiqUniqueJobs::LockArgs.call(critical_job)

    expect(long_job["lock_args"]).to eq([purchase.id])
    expect(critical_job["lock_args"]).to eq([purchase.id])
    expect(SidekiqUniqueJobs::LockDigest.call(long_job)).to eq(SidekiqUniqueJobs::LockDigest.call(critical_job))
    expect(described_class.sidekiq_options["unique_across_queues"]).to be(true)
  end

  it "enqueues files ready email when the buyer asked to be notified while a checkout stamp was already queued" do
    purchase.create_url_redirect!
    PdfStampingService.request_buyer_notification!(purchase.id)

    expect do
      described_class.new.perform(purchase.id)
    end.to have_enqueued_mail(CustomerMailer, :files_ready_for_download).with(purchase.id)

    expect(PdfStampingService.buyer_notification_requested?(purchase.id)).to be(false)
  end

  it "still emails after the old cache window has expired and the cache has been evicted" do
    purchase.create_url_redirect!
    PdfStampingService.request_buyer_notification!(purchase.id)
    PdfStampingService.request_buyer_notification!(purchase.id)

    travel 5.hours do
      Rails.cache.clear

      expect(PdfStampingService.buyer_notification_requested?(purchase.id)).to be(true)
      expect do
        described_class.new.perform(purchase.id)
      end.to have_enqueued_mail(CustomerMailer, :files_ready_for_download).with(purchase.id)
    end

    expect(PdfStampingService.buyer_notification_requested?(purchase.id)).to be(false)
  end

  it "keeps the request when stamping fails so a retry can still email" do
    purchase.create_url_redirect!
    PdfStampingService.request_buyer_notification!(purchase.id)
    allow(PdfStampingService).to receive(:stamp_for_purchase!).and_raise(PdfStampingService::Error)

    expect { described_class.new.perform(purchase.id) }.to raise_error(PdfStampingService::Error)
    expect(PdfStampingService.buyer_notification_requested?(purchase.id)).to be(true)
  end

  it "keeps the request when the files-ready mail cannot be enqueued" do
    purchase.create_url_redirect!
    PdfStampingService.request_buyer_notification!(purchase.id)
    allow(CustomerMailer).to receive(:files_ready_for_download).and_raise(StandardError, "enqueue failed")

    expect { described_class.new.perform(purchase.id) }.to raise_error(StandardError, "enqueue failed")
    expect(PdfStampingService.buyer_notification_requested?(purchase.id)).to be(true)
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

    it "logs and re-raises so Sidekiq retries" do
      expect(Rails.logger).to receive(:error).with(/Failed stamping for purchase #{purchase.id}:/)
      expect { described_class.new.perform(purchase.id) }.to raise_error(PdfStampingService::Error)
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
