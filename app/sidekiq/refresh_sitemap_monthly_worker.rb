# frozen_string_literal: true

class RefreshSitemapMonthlyWorker
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :low

  def perform
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
end
