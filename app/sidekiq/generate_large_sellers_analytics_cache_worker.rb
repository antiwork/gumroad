# frozen_string_literal: true

class GenerateLargeSellersAnalyticsCacheWorker
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :low, lock: :until_executed

  def perform
    User.joins(:large_seller).find_each do |user|
      CreatorAnalytics::CachingProxy.new(user).generate_cache
    rescue => e
      Bugsnag.notify(e) do |report|
        report.add_tab(:user_info, id: user.id)
      end
    end
  end
end
