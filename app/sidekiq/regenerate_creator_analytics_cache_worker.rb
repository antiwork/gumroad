# frozen_string_literal: true

class RegenerateCreatorAnalyticsCacheWorker
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :low, lock: :until_executed

  def perform(user_id, date_string)
    user = User.find(user_id)
    date = Date.parse(date_string)
    service = CreatorAnalytics::CachingProxy.new(user)
    WithMaxExecutionTime.timeout_queries(seconds: 20.minutes) do
      [:date, :state, :referral].each do |type|
        service.overwrite_cache(date, by: type)
      end
    end
  end
end
