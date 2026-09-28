# frozen_string_literal: true

class RefreshWishlistSitemapDailyWorker
  include Sidekiq::Job
  # The wishlist sitemap is rewritten wholesale each run, so a retry is free.
  sidekiq_options retry: 3, queue: :low

  def perform
    SitemapService.new.generate_wishlists
  rescue SitemapService::GenerationInProgress
    # Another run owns the shared SitemapGenerator config, so writing now would land these
    # links in its path instead.
    self.class.perform_in(SitemapService::GENERATION_RETRY_DELAY)
  end
end
