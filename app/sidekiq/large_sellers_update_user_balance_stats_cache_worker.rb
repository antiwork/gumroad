# frozen_string_literal: true

class LargeSellersUpdateUserBalanceStatsCacheWorker
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :low

  def perform
    user_ids = UserBalanceStatsService.cacheable_users.pluck(:id).map { |el| [el] }

    Sidekiq::Client.push_bulk(
      "class" => UpdateUserBalanceStatsCacheWorker,
      "args" => user_ids,
    )
  end
end
