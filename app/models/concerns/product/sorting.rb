# frozen_string_literal: true

module Product::Sorting
  extend ActiveSupport::Concern

  ES_SORT_KEYS = ["display_price_cents", "is_recommendable"]
  SQL_SORT_KEYS = ["name", "successful_sales_count", "status", "taxonomy", "display_product_reviews", "revenue", "cut"]
  SORT_KEYS = ES_SORT_KEYS + SQL_SORT_KEYS

  SORT_KEYS.each do |key|
    const_set(key.upcase, key)
  end

  class_methods do
    def sorted_by(key: nil, direction: nil, user_id:)
      direction = direction == "desc" ? "desc" : "asc"
      case key
      when NAME
        order(name: direction)
      when CUT
        joins(:affiliates)
          .joins(:product_affiliates)
          .order(Arel.sql("CASE
                            WHEN links.user_id = #{user_id} THEN 10000 - affiliates_links.affiliate_basis_points
                            ELSE affiliates_links.affiliate_basis_points
                          END #{direction}"))
      when SUCCESSFUL_SALES_COUNT
        with_latest_product_cached_values(user_id:).order("latest_product_cached_values.successful_sales_count" => direction)
      when STATUS
        order(Arel.sql("links.purchase_disabled_at IS NULL #{direction}"))
      when TAXONOMY
        order(Arel.sql("links.taxonomy_id IS NULL #{direction}"))
      when DISPLAY_PRODUCT_REVIEWS
        order(Arel.sql("links.flags & #{Link.flag_mapping["flags"][:display_product_reviews]} #{direction}"))
      when REVENUE
        with_latest_product_cached_values(user_id:).order("latest_product_cached_values.total_usd_cents" => direction)
      else
        all
      end
    end

    def elasticsearch_sorted_and_paginated_by(key: nil, direction: nil, page:, per_page:, user_id:)
      direction = direction == "desc" ? "desc" : "asc"
      sort = nil

      case key
      when DISPLAY_PRICE_CENTS
        sort = direction == "desc" ? ProductSortKey::AVAILABLE_PRICE_DESCENDING : ProductSortKey::AVAILABLE_PRICE_ASCENDING
      when IS_RECOMMENDABLE
        sort = direction == "desc" ? ProductSortKey::IS_RECOMMENDABLE_DESCENDING : ProductSortKey::IS_RECOMMENDABLE_ASCENDING
      else
        return { page: 1, pages: 1 }, self
      end

      response = Link.search(Link.search_options(
        {
          user_id:,
          ids: self.pluck(:id),
          sort:,
          size: per_page,
          from: per_page * (page.to_i - 1) + 1
        }
      ))
      pages = (response.results.total / per_page.to_f).ceil

      return { page:, pages: }, response.records
    end

    def elasticsearch_key?(key)
      ES_SORT_KEYS.include?(key)
    end
  end
end
