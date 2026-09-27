# frozen_string_literal: true

require "spec_helper"

describe RefreshWishlistSitemapDailyWorker do
  describe "#perform" do
    it "generates the wishlist sitemap" do
      service = instance_double(SitemapService)
      allow(SitemapService).to receive(:new).and_return(service)
      expect(service).to receive(:generate_wishlists)

      described_class.new.perform
    end

    # A loser must come back later rather than write into the run in flight's file.
    it "re-enqueues itself when another sitemap generation is already running" do
      service = instance_double(SitemapService)
      allow(SitemapService).to receive(:new).and_return(service)
      expect(service).to receive(:generate_wishlists).and_raise(SitemapService::GenerationInProgress)

      described_class.new.perform

      expect(described_class).to have_enqueued_sidekiq_job.in(SitemapService::GENERATION_RETRY_DELAY)
    end
  end
end
