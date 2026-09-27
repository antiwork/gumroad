# frozen_string_literal: true

class RefreshWishlistSitemapDailyWorker
  include Sidekiq::Job
  # The wishlist sitemap is rewritten wholesale each run, so a retry is free.
  sidekiq_options retry: 3, queue: :low

  def perform
    SitemapService.new.generate_wishlists
  rescue SitemapService::GenerationInProgress
    # A product or category run owns the shared SitemapGenerator config; writing now would
    # land this run's links in that run's path (and vice versa). Come back once it's done.
    self.class.perform_in(SitemapService::GENERATION_RETRY_DELAY)
  end
end
