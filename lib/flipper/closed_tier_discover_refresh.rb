# frozen_string_literal: true

module Flipper
  module ClosedTierDiscoverRefresh
    FEATURE_NAME = "close_membership_tier_to_new_buyers"

    def enable(thing = true)
      result = super
      refresh_closed_tier_discover_prices(thing)
      result
    end

    def disable(thing = false)
      result = super
      refresh_closed_tier_discover_prices(thing)
      result
    end

    private
      def refresh_closed_tier_discover_prices(thing)
        return unless name.to_s == FEATURE_NAME

        actor = thing.respond_to?(:actor) ? thing.actor : thing
        user = actor if actor.is_a?(User)
        Link.refresh_discover_prices_for_closed_tiers(user:)
      end
  end
end

Flipper::Feature.prepend(Flipper::ClosedTierDiscoverRefresh)
