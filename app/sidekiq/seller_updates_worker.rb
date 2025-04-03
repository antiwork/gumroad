# frozen_string_literal: true

class SellerUpdatesWorker
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default, lock: :until_executed

  def perform
    User.by_sales_revenue(days_ago: 7.days.ago, limit: nil) do |user|
      SellerUpdateWorker.perform_async(user.id)
    end
  end
end
