# frozen_string_literal: true

# Unfinished sales the seller can see. Reads the primary so a sale is not hidden
# while search indexing lags. Does not include these rows in completed revenue.
class SellerInFlightSales
  MAX_ROWS = 100

  def initialize(seller)
    @seller = seller
  end

  def records(
    query: nil,
    email: nil,
    name: nil,
    products: nil,
    product_id: nil,
    purchase_id: nil,
    variants: nil,
    excluded_products: nil,
    excluded_variants: nil,
    minimum_amount_cents: nil,
    maximum_amount_cents: nil,
    created_after: nil,
    created_before: nil,
    country: nil,
    license_key: nil,
    minimum_license_uses: nil,
    exclude_recurring_charges: false,
    sort_key: nil,
    sort_direction: nil,
    offset: 0,
    limit: MAX_ROWS
  )
    return [] if minimum_license_uses.present?

    ApplicationRecord.connected_to(role: :writing) do
      direction = sort_direction == "asc" ? "ASC" : "DESC"
      relation = filtered_scope(
        query:, email:, name:, products:, product_id:, purchase_id:, variants:,
        excluded_products:, excluded_variants:, minimum_amount_cents:, maximum_amount_cents:,
        created_after:, created_before:, country:, license_key:, exclude_recurring_charges:
      )
      relation = relation.left_joins(:link) if sort_key == "product_name"
      order_sql = case sort_key
                  when "price_cents" then "purchases.price_cents #{direction}, purchases.id #{direction}"
                  when "product_name" then "links.name #{direction}, purchases.id #{direction}"
                  else "purchases.created_at #{direction}, purchases.id #{direction}"
      end
      relation.order(Arel.sql(order_sql)).offset(offset).limit(limit).to_a
    end
  end

  def matching_count(**filters)
    return 0 if filters[:minimum_license_uses].present?

    ApplicationRecord.connected_to(role: :writing) do
      filtered_scope(**filters.except(:offset, :limit, :minimum_license_uses, :sort_key, :sort_direction)).count
    end
  end

  def count(**filters)
    return 0 if filters[:minimum_license_uses].present?

    ApplicationRecord.connected_to(role: :writing) do
      scope = @seller.sales.seller_visible_in_flight
      scope = scope.where(link_id: filters[:product_id]) if filters[:product_id].present?
      scope = scope.where("purchases.created_at >= ?", filters[:created_after]) if filters[:created_after].present?
      scope = scope.where("purchases.created_at < ?", filters[:created_before]) if filters[:created_before].present?
      scope.unscope(:order).count("DISTINCT purchases.id")
    end
  end

  def counts_by_product(product_ids)
    return {} if product_ids.blank?

    ApplicationRecord.connected_to(role: :writing) do
      @seller.sales.seller_visible_in_flight
        .not_recurring_charge
        .where(link_id: product_ids)
        .unscope(:order)
        .group(:link_id)
        .count("DISTINCT purchases.id")
    end
  end

  def gross_cents(created_after:, created_before:)
    ApplicationRecord.connected_to(role: :writing) do
      ids = @seller.sales.seller_visible_in_flight
        .where("purchases.created_at >= ?", created_after)
        .where("purchases.created_at < ?", created_before)
        .unscope(:order)
        .distinct
        .select(:id)
      Purchase.where(id: ids).sum(:price_cents)
    end
  end

  private
    def filtered_scope(
      query: nil, email: nil, name: nil, products: nil, product_id: nil, purchase_id: nil, variants: nil,
      excluded_products: nil, excluded_variants: nil, minimum_amount_cents: nil, maximum_amount_cents: nil,
      created_after: nil, created_before: nil, country: nil, license_key: nil, exclude_recurring_charges: false
    )
      scope = @seller.sales.seller_visible_in_flight
      scope = scope.not_recurring_charge if exclude_recurring_charges
      scope = apply_text_filter(scope, query) if query.present?
      scope = scope.where(email:) if email.present?
      scope = scope.where("full_name LIKE ?", "%#{Purchase.sanitize_sql_like(name)}%") if name.present?
      scope = apply_product_or_variant_filter(scope, products, variants)
      scope = scope.where(link_id: product_id) if product_id.present?
      scope = scope.where(id: purchase_id) if purchase_id.present?
      scope = exclude_purchasers(scope, excluded_products, excluded_variants)
      scope = scope.where("purchases.price_cents > ?", minimum_amount_cents) if minimum_amount_cents.present?
      scope = scope.where("purchases.price_cents < ?", maximum_amount_cents) if maximum_amount_cents.present?
      scope = scope.where("purchases.created_at >= ?", created_after) if created_after.present?
      scope = scope.where("purchases.created_at < ?", created_before) if created_before.present?
      scope = scope.where(
        "purchases.country IN (:names) OR (NULLIF(purchases.country, '') IS NULL AND purchases.ip_country IN (:names))",
        names: Array(country)
      ) if country.present?
      scope = scope.where(id: license_purchase_ids(license_key)) if license_key.present?
      scope
    end

    def apply_product_or_variant_filter(scope, products, variants)
      product_ids = products&.map(&:id)
      variant_ids = variants&.map(&:id)
      return scope if product_ids.blank? && variant_ids.blank?

      matching_product = product_ids.present? ? scope.where(link_id: product_ids) : nil
      matching_variant = if variant_ids.present?
        scope.where(id: Purchase.joins(:variant_attributes).where(base_variants: { id: variant_ids }).select(:id))
      end
      return matching_product if matching_variant.nil?
      return matching_variant if matching_product.nil?

      matching_product.or(matching_variant)
    end

    def exclude_purchasers(scope, products, variants)
      if products.present?
        product_ids = products.map(&:id)
        scope = scope.where.not(link_id: product_ids)
        scope = scope.where.not(email: @seller.sales.successful.where(link_id: product_ids).select(:email))
      end
      if variants.present?
        variant_ids = variants.map(&:id)
        variant_purchase_ids = Purchase.joins(:variant_attributes).where(base_variants: { id: variant_ids }).select(:id)
        scope = scope.where.not(id: variant_purchase_ids)
        scope = scope.where.not(email: @seller.sales.successful.joins(:variant_attributes).where(base_variants: { id: variant_ids }).select(:email))
      end
      scope
    end

    def apply_text_filter(scope, query)
      like = "%#{Purchase.sanitize_sql_like(query)}%"
      scope.left_joins(:link).where(
        "(purchases.email LIKE :like OR purchases.full_name LIKE :like OR links.name LIKE :like)",
        like:
      )
    end

    def license_purchase_ids(license_key)
      holder_ids = License.where(serial: license_key.upcase).select(:purchase_id)
      Purchase.unscoped
        .where(id: holder_ids)
        .joins("LEFT JOIN gifts ON gifts.giftee_purchase_id = purchases.id")
        .select("COALESCE(gifts.gifter_purchase_id, purchases.id)")
    end
end
