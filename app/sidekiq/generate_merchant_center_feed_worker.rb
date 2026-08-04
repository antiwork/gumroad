# frozen_string_literal: true

class GenerateMerchantCenterFeedWorker
  include Sidekiq::Job
  # Each run rewrites the feed object wholesale, so retries are free. Failures propagate
  # so Sidekiq's Sentry integration reports them.
  sidekiq_options retry: 3, queue: :low

  def perform(max_products = MerchantCenterFeedService::DEFAULT_MAX_PRODUCTS)
    MerchantCenterFeedService.new.generate(max_products:)
  end
end
