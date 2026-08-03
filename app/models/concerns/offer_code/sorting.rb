# frozen_string_literal: true

module OfferCode::Sorting
  extend ActiveSupport::Concern

  SORT_KEYS = ["name", "revenue", "uses", "term"]
  USES_SORT_SQL = <<~SQL.squish
    COALESCE(SUM(
      CASE
        WHEN purchase_offer_code_discounts.once_per_cart = TRUE
          THEN CASE WHEN purchase_offer_code_discounts.once_per_cart_allocation_id IS NULL THEN 1 ELSE 0 END
        ELSE purchases.quantity
      END
    ), 0) + COUNT(DISTINCT CASE
      WHEN purchase_offer_code_discounts.once_per_cart = TRUE
        THEN purchase_offer_code_discounts.once_per_cart_allocation_id
    END)
  SQL

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
        left_outer_joins(:purchases_that_count_towards_offer_code_revenue)
          .group(:id)
          .order("SUM(purchases.price_cents) #{direction}")
      when USES
        left_outer_joins(purchases_that_count_towards_offer_code_uses: :purchase_offer_code_discount)
          .group(:id)
          .order(Arel.sql("#{USES_SORT_SQL} #{direction}"))
      when TERM
        order(valid_at: direction, expires_at: direction)
      else
        all
      end
    end
  end
end
