# frozen_string_literal: true

module Product::Caching
  def scoped_cache_key(locale, fragmented = false, displayed_switch_ids = [], prefetched_cache_key_prefix = nil, request_host = nil)
    displayed_switch_ids = displayed_switch_ids.sort
    displayed_switch_ids = displayed_switch_ids.join("_")
    prefix = prefetched_cache_key_prefix || cache_key_prefix
    request_host_key = "_#{request_host}" if request_host.present?
    fragmented_key = "_fragmented" if fragmented

    "#{prefix}#{request_host_key}_#{locale}#{fragmented_key}_displayed_switch_ids_#{displayed_switch_ids}"
  end

  def invalidate_cache
    Rails.cache.delete("link_cache_key_prefix_#{id}")
    product_cached_values.fresh.each(&:expire!)
  end

  def cache_key_prefix
    Rails.cache.fetch(key_for_cache_key_prefix) do
      generate_cache_key_prefix
    end
  end

  def generate_cache_key_prefix
    "#{id}_#{SecureRandom.uuid}"
  end

  def key_for_cache_key_prefix
    "link_cache_key_prefix_#{id}"
  end

  def self.scoped_cache_keys(products, displayed_switch_ids_for_products, locale, fragmented = false)
    scoped_keys = []
    cache_key_prefixes(products).each_with_index do |(key, prefix), i|
      scoped_keys.push products[i].scoped_cache_key(locale, fragmented, displayed_switch_ids_for_products[i], prefix)
    end
    scoped_keys
  end

  def self.cache_key_prefixes(products)
    indexed_products = products.index_by(&:key_for_cache_key_prefix)
    Rails.cache.fetch_multi(*indexed_products.keys) do |key|
      "#{indexed_products[key].id}_#{SecureRandom.uuid}"
    end
  end

  def self.dashboard_collection_data(collection, cache: false)
    cached_values = []

    product_ids = collection.pluck(:id)
    cached_values = ProductCachedValue.fresh.where(product_id: product_ids)
    uncached_product_ids = (product_ids - cached_values.pluck(:product_id)).zip

    CacheProductDataWorker.perform_bulk(uncached_product_ids) if cache && !uncached_product_ids.empty?

    collection.map do |product|
      cache_or_product = cached_values.find { |cached_value| cached_value.product_id == product.id } || product
      if block_given?
        yield(product).merge(
          {
            "successful_sales_count" => cache_or_product.successful_sales_count,
            "remaining_for_sale_count" => cache_or_product.remaining_for_sale_count,
            "monthly_recurring_revenue" => cache_or_product.monthly_recurring_revenue.to_f,
            "revenue_pending" => cache_or_product.revenue_pending.to_f,
            "total_usd_cents" => cache_or_product.total_usd_cents.to_f,
          }
        )
      else
        cache_or_product
      end
    end
  end
end
