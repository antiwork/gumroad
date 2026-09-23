# frozen_string_literal: true

# Counts the buyers who can still reach each file, for the editor's downloads-off confirmation:
# successful purchases only, distinct buyers, and a variant-scoped file counts its variants'
# buyers. Reach through rich content is not modeled, so this is an upper bound.
class ProductFileBuyerCountsService
  CACHE_KEY_PREFIX = "product_file_buyer_counts"
  CACHE_TTL = 1.minute

  def initialize(product:)
    @product = product
  end

  # Public: { product_file.external_id => Integer }
  #
  # The editor's file lists read this on every page load, so it is cached for a minute and keyed on
  # the newest sale, like ProductPresenter.cached_sales_count. A purchase whose state changes
  # without adding a sale row (a refund) can leave the cached reading up to that minute stale.
  def counts_by_external_id
    Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) { compute_counts_by_external_id }
  end

  private
    attr_reader :product

    def cache_key
      latest_sale_id = product.sales.order(id: :desc).pick(:id)
      digest = Digest::SHA256.hexdigest("#{product.cache_key}-#{latest_sale_id}")
      "#{CACHE_KEY_PREFIX}_#{digest}"
    end

    def compute_counts_by_external_id
      files = alive_files
      return {} if files.empty?

      product_wide_count = buyers_count
      variant_counts = variant_scoped_counts(files)

      files.each_with_object({}) do |file, counts|
        counts[file.external_id] =
          if file.base_variants.empty?
            product_wide_count
          else
            variant_counts.fetch(file.id, 0)
          end
      end
    end

    def alive_files
      @alive_files ||= product.product_files.alive.in_order.includes(:base_variants).to_a
    end

    def buyers
      @buyers ||= product.sales
        .successful_or_preorder_authorization_successful_and_not_refunded_or_chargedback
    end

    def buyers_count
      @buyers_count ||= buyers.distinct.count(buyer_identity)
    end

    # A guest purchase has no `purchaser_id`, so its email carries the identity there; recurring
    # charges share both, which is what collapses a membership's renewals into one buyer.
    def buyer_identity
      Arel.sql("COALESCE(purchases.purchaser_id, purchases.email)")
    end

    # One query for every variant-scoped file on the page: a buyer counts once per file even
    # when they hold more than one of that file's variants, or paid through recurring charges.
    def variant_scoped_counts(files)
      scoped_file_ids = files.reject { _1.base_variants.empty? }.map(&:id)
      return {} if scoped_file_ids.empty?

      BaseVariantsPurchase
        .joins("INNER JOIN base_variants_product_files ON base_variants_product_files.base_variant_id = base_variants_purchases.base_variant_id")
        .joins("INNER JOIN purchases ON purchases.id = base_variants_purchases.purchase_id")
        .where(base_variants_product_files: { product_file_id: scoped_file_ids })
        .where(base_variants_purchases: { purchase_id: buyers.select(:id) })
        .group("base_variants_product_files.product_file_id")
        .distinct
        .count(buyer_identity)
    end
end
