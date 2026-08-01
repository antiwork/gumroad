# frozen_string_literal: true

class RefreshSitemapDailyWorker
  include Sidekiq::Job
  # Regenerating a month's sitemap overwrites it wholesale, so a retry is free. Without a
  # budget a single killed run left that month's file frozen until the next nightly pass,
  # and a run that kept dying left it frozen indefinitely with nothing recorded anywhere
  # (gumroad-private#1679). Given the retry, LongRunningJobTracking no longer applies —
  # see the exclusion list in that module.
  sidekiq_options retry: 3, queue: :low

  def perform(date = Date.current.to_s)
    SitemapService.new.generate(date)
  end
end
