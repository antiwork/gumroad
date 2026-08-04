# frozen_string_literal: true

class RefreshWishlistSitemapDailyWorker
  include Sidekiq::Job
  # The wishlist sitemap is rewritten wholesale each run, so a retry is free.
  sidekiq_options retry: 3, queue: :low

  def perform
    SitemapService.new.generate_wishlists
  end
end
