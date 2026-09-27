# frozen_string_literal: true

class RefreshSitemapMonthlyWorker
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :low

  # A retry must not re-run #perform: that re-enqueues the product chain, whose first job runs
  # immediately — the likeliest holder of the lock the categories step just lost — so each pass
  # would rebuild its own conflict. Retried with this marker, the step skips the loop.
  CATEGORIES_ONLY = "categories_only"
  # 15 minutes apart, so 24 attempts span six hours: longer than the product chain that causes
  # the contention, while still stopping a retry tail that can never land.
  CATEGORIES_MAX_ATTEMPTS = 24

  def perform(step = nil, attempt = 1)
    unless step == CATEGORIES_ONLY
      # Update sitemap of products updated in the last month
      last_month_start = 1.month.ago.beginning_of_month
      last_month_end = last_month_start.end_of_month

      updated_products = Link.select("DISTINCT DATE_FORMAT(created_at,'01-%m-%Y') AS created_month").where(updated_at: (last_month_start..last_month_end))
      product_created_months = updated_products.map do |product|
        Date.parse(product.attributes["created_month"])
      end

      # Generate sitemaps with 30 minutes gap to reduce the pressure on DB
      product_created_months.each_with_index do |month, index|
        RefreshSitemapDailyWorker.perform_in((30 * index).minutes, month.to_s)
      end
    end

    # Last, because retry is 0 here: a category failure must not cost the product sitemaps
    # their refresh, and losing the shared lock must not drop the categories sitemap for a
    # month either.
    refresh_categories(attempt)
  end

  private
    def refresh_categories(attempt)
      SitemapService.new.generate_categories
    rescue SitemapService::GenerationInProgress
      if attempt < CATEGORIES_MAX_ATTEMPTS
        self.class.perform_in(SitemapService::GENERATION_RETRY_DELAY, CATEGORIES_ONLY, attempt + 1)
      else
        Rails.logger.error(
          "RefreshSitemapMonthlyWorker gave up on the categories sitemap after #{attempt} lock conflicts"
        )
      end
    end
end
