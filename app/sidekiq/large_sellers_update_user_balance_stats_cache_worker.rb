# frozen_string_literal: true

class LargeSellersUpdateUserBalanceStatsCacheWorker
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :low

  STAGGER_WINDOW = 1.hour
  PUSH_BULK_BATCH_SIZE = 1_000

  def perform
    user_ids = UserBalanceStatsService.cacheable_users.pluck(:id)
    return if user_ids.empty?

    delay_step = STAGGER_WINDOW.to_f / user_ids.size
    base_time = Time.current.to_f

    user_ids.each_slice(PUSH_BULK_BATCH_SIZE).with_index do |slice, chunk_index|
      offset = chunk_index * PUSH_BULK_BATCH_SIZE
      Sidekiq::Client.push_bulk(
        "class" => UpdateUserBalanceStatsCacheWorker,
        "args" => slice.map { |id| [id] },
        "at" => slice.each_index.map { |i| base_time + ((offset + i) * delay_step) },
      )
    end
  end
end
