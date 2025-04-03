# frozen_string_literal: true

class BuildTaxRateCacheWorker
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default

  def perform
    us_tax_cache_namespace = Redis::Namespace.new(:max_tax_rate_per_state_cache_us, redis: $redis)
    ZipTaxRate.where("state is NOT NULL").group(:state).maximum(:combined_rate).each do |state_and_max_rate|
      state_with_prefix = "US_" + state_and_max_rate[0]
      us_tax_cache_namespace.set(state_with_prefix,  state_and_max_rate[1])
    end
  end
end
