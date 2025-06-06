# frozen_string_literal: true

class UpdateLargeSellersSalesCountJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :low

  def perform
    LargeSeller.find_each(batch_size: 100) do |large_seller|
      next unless large_seller.user

      current_sales_count = large_seller.user.sales.count

      if current_sales_count != large_seller.sales_count
        large_seller.update!(sales_count: current_sales_count)
      end
    end
  end
end
