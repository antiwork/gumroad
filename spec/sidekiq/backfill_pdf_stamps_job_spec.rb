# frozen_string_literal: true

require "spec_helper"

describe BackfillPdfStampsJob do
  let(:product) { create(:product_with_pdf_file) }
  let!(:older_purchase) { create(:purchase, link: product) }
  let!(:newer_purchase) { create(:purchase, link: product) }

  before do
    older_purchase.create_url_redirect!
    newer_purchase.create_url_redirect!
    allow(PdfStampingService).to receive(:stamp_for_purchase!)
  end

  it "stamps sales inline instead of enqueuing a locked job per sale" do
    described_class.new.perform(product.id)

    expect(PdfStampingService).to have_received(:stamp_for_purchase!).with(older_purchase)
    expect(PdfStampingService).to have_received(:stamp_for_purchase!).with(newer_purchase)
    expect(StampPdfForPurchaseJob.jobs).to be_empty
    expect(described_class.jobs).to be_empty
  end

  it "skips sales without a download page" do
    create(:purchase, link: product)

    described_class.new.perform(product.id)

    expect(PdfStampingService).to have_received(:stamp_for_purchase!).twice
  end

  it "schedules the next slice after a full batch" do
    stub_const("#{described_class}::BATCH_SIZE", 1)

    described_class.new.perform(product.id)

    expect(PdfStampingService).to have_received(:stamp_for_purchase!).once.with(newer_purchase)
    expect(described_class).to have_enqueued_sidekiq_job(product.id, newer_purchase.id).in(described_class::DELAY_BETWEEN_BATCHES)

    described_class.new.perform(product.id, newer_purchase.id)

    expect(PdfStampingService).to have_received(:stamp_for_purchase!).with(older_purchase)
  end

  it "keeps going when one sale fails to stamp" do
    allow(PdfStampingService).to receive(:stamp_for_purchase!).with(newer_purchase).and_raise(PdfStampingService::Error, "bad pdf")

    expect { described_class.new.perform(product.id) }.not_to raise_error

    expect(PdfStampingService).to have_received(:stamp_for_purchase!).with(older_purchase)
  end
end
