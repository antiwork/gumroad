# frozen_string_literal: true

class RefreshClosedTierDiscoverPricesJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low

  def perform
    Link.refresh_discover_prices_for_closed_tiers
  end
end
