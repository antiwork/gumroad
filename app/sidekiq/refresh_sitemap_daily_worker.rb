# frozen_string_literal: true

class RefreshSitemapDailyWorker
  include Sidekiq::Job
  include LongRunningJobTracking
  sidekiq_options retry: 0, queue: :low

  def perform(date = Date.current.to_s)
    SitemapService.new.generate(date)
  end
end
