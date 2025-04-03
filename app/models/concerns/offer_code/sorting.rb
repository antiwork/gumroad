# frozen_string_literal: true

module OfferCode::Sorting
  extend ActiveSupport::Concern

  SORT_KEYS = ["name", "revenue", "uses", "term"]

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
        left_outer_joins(:purchases_that_count_towards_offer_code_uses)
          .group(:id)
          .order("SUM(purchases.price_cents) #{direction}")
      when USES
        left_outer_joins(:purchases_that_count_towards_offer_code_uses)
          .group(:id)
          .order("SUM(purchases.quantity) #{direction}")
      when TERM
        order(valid_at: direction, expires_at: direction)
      else
        all
      end
    end
  end
end
