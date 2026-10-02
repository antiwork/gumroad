# frozen_string_literal: true

class GenerateMerchantCenterFeedWorker
  include Sidekiq::Job
  # Each run rewrites its feed objects wholesale and resumes after the files it already
  # finished, so retries are cheap. Failures propagate so Sidekiq's Sentry integration reports them.
  sidekiq_options retry: 3, queue: :low

  # A run killed without releasing its lock (OOM, deploy) blocks the feed until the lock expires,
  # which is longer than Sidekiq's retry backoff. Waiting for it here instead of through retry
  # spans MerchantCenterFeedRun::LOCK_TTL.
  LOCK_RETRY_DELAY = 5.minutes
  LOCK_MAX_ATTEMPTS = 5

  def perform(max_products = MerchantCenterFeedService::DEFAULT_MAX_PRODUCTS, attempt = 1)
    MerchantCenterFeedRun.new.call(max_products:)
  rescue MerchantCenterFeedRun::GenerationInProgress
    raise if attempt >= LOCK_MAX_ATTEMPTS

    self.class.perform_in(LOCK_RETRY_DELAY, max_products, attempt + 1)
  end
end
