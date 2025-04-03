# frozen_string_literal: true

class UpdateUserBalanceStatsCacheWorker
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :low, lock: :until_executed

  def perform(user_id)
    user = User.find(user_id)

    WithMaxExecutionTime.timeout_queries(seconds: 1.hour) do
      UserBalanceStatsService.new(user:).write_cache
    end
  end
end
