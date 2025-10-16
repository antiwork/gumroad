# frozen_string_literal: true

module Upsell::Sorting
  extend ActiveSupport::Concern

  SORT_KEYS = ["name", "revenue", "uses", "status"]

  SORT_KEYS.each do |key|
    const_set(key.upcase, key)
  end

  class_methods do
    def sorted_by(key: nil, direction: nil)
      direction = direction == "desc" ? "desc" : "asc"
      case key
      when NAME
        order(name: direction)
      when REVENUE
        left_outer_joins(:purchases_that_count_towards_volume)
          .group(:id)
          .order("SUM(purchases.price_cents) #{direction}")
      when USES
        left_outer_joins(:purchases_that_count_towards_volume)
          .group(:id)
          .order("SUM(purchases.quantity) #{direction}")
      when STATUS
        order(paused: direction)
      else
        all
      end
    end
  end
end
