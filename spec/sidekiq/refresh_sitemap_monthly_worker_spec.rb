# frozen_string_literal: true

require "spec_helper"

describe RefreshSitemapMonthlyWorker do
  describe "#perform" do
    # Frozen because the assertion below checks the exact time the second job is scheduled
    # for, and the matcher truncates both that time and its own expected time to whole
    # seconds — so a clock tick across a second boundary in between fails the test at random.
    it "enqueues jobs to generate sitemaps for products updated in last month", :freeze_time do
      product_1 = create(:product, created_at: 3.months.ago)
      product_2 = create(:product, created_at: 2.months.ago)
      # Set the timestamp after creation: the factory's `price_cents` builds a Price, whose
      # commit touches the product, so an `updated_at:` passed to `create` gets overwritten.
      # `update_columns` skips callbacks, leaving the products inside the worker's window.
      [product_1, product_2].each { _1.update_columns(updated_at: 1.month.ago) }

      described_class.new.perform

      expect(RefreshSitemapDailyWorker).to have_enqueued_sidekiq_job(product_1.created_at.beginning_of_month.to_date.to_s)
      expect(RefreshSitemapDailyWorker).to have_enqueued_sidekiq_job(product_2.created_at.beginning_of_month.to_date.to_s).in(30.minutes)
    end

    it "doesn't enqueue jobs to generate sitemaps updated in the current month" do
      create(:product)

      described_class.new.perform

      expect(RefreshSitemapDailyWorker.jobs.size).to eq(0)
    end

    # retry is 0 here, and the product chain this worker enqueues starts immediately, so a
    # lost race for the shared SitemapGenerator config must re-enqueue the categories pass.
    it "re-enqueues the categories step when it has to wait for another run", :freeze_time do
      service = instance_double(SitemapService)
      allow(SitemapService).to receive(:new).and_return(service)
      expect(service).to receive(:generate_categories).and_raise(SitemapService::GenerationInProgress)

      described_class.new.perform

      expect(described_class).to have_enqueued_sidekiq_job(described_class::CATEGORIES_ONLY, 2)
        .in(SitemapService::GENERATION_RETRY_DELAY)
    end

    # Re-running the full pass on retry would enqueue the product chain again, and the chain's
    # first job runs immediately — so it would rebuild the conflict it just lost, one duplicate
    # chain per pass, while the categories sitemap might never land.
    it "retries the categories step alone, without enqueueing the product chain again", :freeze_time do
      product = create(:product, created_at: 3.months.ago)
      product.update_columns(updated_at: 1.month.ago)
      service = instance_double(SitemapService)
      allow(SitemapService).to receive(:new).and_return(service)
      expect(service).to receive(:generate_categories).and_raise(SitemapService::GenerationInProgress)

      described_class.new.perform(described_class::CATEGORIES_ONLY, 2)

      expect(RefreshSitemapDailyWorker.jobs.size).to eq(0)
      expect(described_class).to have_enqueued_sidekiq_job(described_class::CATEGORIES_ONLY, 3)
        .in(SitemapService::GENERATION_RETRY_DELAY)
    end

    it "stops retrying after CATEGORIES_MAX_ATTEMPTS and reports it" do
      service = instance_double(SitemapService)
      allow(SitemapService).to receive(:new).and_return(service)
      expect(service).to receive(:generate_categories).and_raise(SitemapService::GenerationInProgress)
      allow(Rails.logger).to receive(:error)

      described_class.new.perform(described_class::CATEGORIES_ONLY, described_class::CATEGORIES_MAX_ATTEMPTS)

      expect(described_class.jobs.size).to eq(0)
      expect(Rails.logger).to have_received(:error).with(/gave up on the categories sitemap/)
    end
  end
end
