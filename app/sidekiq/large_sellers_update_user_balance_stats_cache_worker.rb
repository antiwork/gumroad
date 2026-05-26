# frozen_string_literal: true

class LargeSellersUpdateUserBalanceStatsCacheWorker
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :low

  STAGGER_WINDOW = 1.hour

  def perform
    user_ids = UserBalanceStatsService.cacheable_users.pluck(:id)
    return if user_ids.empty?

    delay_step = STAGGER_WINDOW.to_f / user_ids.size
    base_time = Time.current.to_f

    Sidekiq::Client.push_bulk(
      "class" => UpdateUserBalanceStatsCacheWorker,
      "args" => user_ids.map { |id| [id] },
      "at" => user_ids.each_index.map { |i| base_time + (i * delay_step) },
    )
  end
end
