# frozen_string_literal: true

module Purchase::Targeting
  extend ActiveSupport::Concern

  included do
    scope :by_variant, lambda { |variant_id|
      if variant_id.present?
        joins("INNER JOIN base_variants_purchases ON base_variants_purchases.purchase_id = purchases.id")
          .where("base_variants_purchases.base_variant_id IN (?)", variant_id)
      end
    }
    scope :email_not,           ->(emails) { where("purchases.email NOT IN (?)", emails) if emails.present? }
    scope :paid_more_than,      ->(more_than_cents) { where("purchases.price_cents > ?", more_than_cents) if more_than_cents.present? }
    scope :paid_less_than,      ->(less_than_cents) { where("purchases.price_cents < ?", less_than_cents) if less_than_cents.present? }
    scope :country_bought_from, ->(country) { where("purchases.country IN (?) OR (purchases.country IS NULL AND purchases.ip_country IN (?))", Compliance::Countries.historical_names(country), Compliance::Countries.historical_names(country)) if country.present? }
    scope :by_external_variant_ids_or_products, ->(external_variant_ids, product_ids) do
      if external_variant_ids.present?
        variant_ids = BaseVariant.by_external_ids(external_variant_ids).pluck(:id)
        by_variants_sql = by_variant(variant_ids).to_sql
        by_products_sql = where(link_id: product_ids).to_sql
        sub_query = "(#{by_variants_sql}) UNION (#{by_products_sql})"
        where("purchases.id IN (SELECT id FROM (#{sub_query}) AS t_purchases)")
      else
        for_products(product_ids)
      end
    end
  end
end
