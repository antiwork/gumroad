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

        seller = seller_for(thing)
        if seller
          Link.refresh_discover_prices_for_closed_tiers(user: seller)
        elsif broad_rollout?(thing)
          RefreshClosedTierDiscoverPricesJob.perform_async
        end
      end

      def broad_rollout?(thing)
        thing == true || thing == false || thing.is_a?(Flipper::Types::Percentage) || thing.is_a?(Flipper::Types::Boolean) || thing.is_a?(Flipper::Types::Group)
      end

      def seller_for(thing)
        actor = thing.respond_to?(:actor) ? thing.actor : thing
        return actor if actor.is_a?(User)

        flipper_id = if actor.respond_to?(:flipper_id)
          actor.flipper_id
        elsif actor.respond_to?(:value)
          actor.value
        else
          actor
        end
        return unless flipper_id.to_s.start_with?("User;")

        User.find_by(id: flipper_id.to_s.split(";", 2).last)
      end
  end
end

Flipper::Feature.prepend(Flipper::ClosedTierDiscoverRefresh)
