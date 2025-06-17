# frozen_string_literal: true

class LargeSellersUpdateUserBalanceStatsCacheWorker
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :low

  def perform
    user_ids = UserBalanceStatsService.cacheable_users.pluck(:id)
    user_ids.each do |user_id|
      UpdateUserBalanceStatsCacheWorker.perform_async(user_id)
    end
  end
end
