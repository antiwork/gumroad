# frozen_string_literal: true

class RefreshSitemapDailyWorker
  include Sidekiq::Job
  include LongRunningJobTracking
  # Regenerating a month's sitemap overwrites it wholesale, so a retry is free. Without a
  # budget a single killed run left that month's file frozen until the next nightly pass,
  # and a run that kept dying left it frozen indefinitely with nothing recorded anywhere
  # (gumroad-private#1679).
  sidekiq_options retry: 3, queue: :low

  def perform(date = Date.current.to_s)
    SitemapService.new.generate(date)
  end
end
