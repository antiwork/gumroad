# frozen_string_literal: true

class GenerateMerchantCenterFeedWorker
  include Sidekiq::Job
  # Failures propagate so Sidekiq's Sentry integration reports them.
  sidekiq_options retry: 3, queue: :low

  # A run killed without releasing its lock outlives Sidekiq's retry backoff; these attempts span
  # MerchantCenterFeedRun::LOCK_TTL instead.
  LOCK_RETRY_DELAY = 5.minutes
  LOCK_MAX_ATTEMPTS = 5

  def perform(max_products = MerchantCenterFeedService::DEFAULT_MAX_PRODUCTS, attempt = 1)
    MerchantCenterFeedRun.new.call(max_products:)
  rescue MerchantCenterFeedRun::GenerationInProgress
    raise if attempt >= LOCK_MAX_ATTEMPTS

    self.class.perform_in(LOCK_RETRY_DELAY, max_products, attempt + 1)
  end
end
