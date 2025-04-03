# frozen_string_literal: true

class CompileGumroadDailyAnalyticsJob
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :default

  REFRESH_PERIOD = 45.days
  private_constant :REFRESH_PERIOD

  def perform
    start_date = Date.today - REFRESH_PERIOD
    end_date = Date.today

    (start_date..end_date).each do |date|
      GumroadDailyAnalytic.import(date)
    end
  end
end
