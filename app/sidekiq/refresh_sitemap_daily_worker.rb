# frozen_string_literal: true

class RefreshSitemapDailyWorker
  include Sidekiq::Job
  # Regenerating a month overwrites its file wholesale, so a retry is free and a killed run
  # loses nothing — which is also why LongRunningJobTracking no longer applies here.
  sidekiq_options retry: 3, queue: :low

  def perform(date = Date.current.to_s)
    SitemapService.new.generate(date)
  rescue SitemapService::GenerationInProgress
    # Another run owns the shared SitemapGenerator config, so these links would be written
    # into its path. Regenerating a month is idempotent — come back.
    self.class.perform_in(SitemapService::GENERATION_RETRY_DELAY, date)
  end
end
