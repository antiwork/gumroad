# frozen_string_literal: true

module Affiliate::Sorting
  extend ActiveSupport::Concern

  SORT_KEYS = ["affiliate_user_name", "products", "fee_percent", "volume_cents"]

  SORT_KEYS.each do |key|
    const_set(key.upcase, key)
  end

  class_methods do
    def sorted_by(key: nil, direction: nil)
      direction = direction == "desc" ? "desc" : "asc"
      case key
      when AFFILIATE_USER_NAME
        joins(:affiliate_user)
          .order(Arel.sql("CASE
                            WHEN users.name IS NOT NULL THEN users.name
                            WHEN users.username != users.external_id THEN users.username
                            WHEN users.unconfirmed_email IS NOT NULL THEN users.unconfirmed_email
                            ELSE users.email
                          END #{direction}"))
      when PRODUCTS
        left_outer_joins(:product_affiliates)
          .group(:id)
          .order("COUNT(affiliates_links.id) #{direction}")
      when FEE_PERCENT
        left_outer_joins(:product_affiliates)
          .group(:id)
          .order("MIN(affiliates_links.affiliate_basis_points) #{direction}")
      when VOLUME_CENTS
        left_outer_joins(:purchases_that_count_towards_volume)
          .group(:id)
          .order("SUM(purchases.price_cents) #{direction}")
      else
        all
      end
    end
  end
end
