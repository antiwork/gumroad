# frozen_string_literal: true

# Counts the buyers who can still reach each file of a product (gumroad-private#2918).
#
# The product editor asks before a seller turns on "read-only" (`stream_only`) for a file:
# the delivery-mode change applies retroactively to everyone who already bought (decision on
# gumroad-private#2916, option 3 — no grandfathering), so the confirmation has to name how
# many existing buyers lose download access. The number is billing-adjacent, so it is derived
# from the purchase records rather than from `product.sales`:
#
#   - Only purchases that still confer access count: successful (or preorder-authorized),
#     not refunded and not charged back — the same scope the seller-facing sales reports use.
#     A fully refunded buyer has no access to lose, and counting them would overstate the
#     warning.
#   - A file attached to specific variants reaches only buyers of those variants. Files with
#     no variant rows are product-wide. Bundle buyers of a product are ordinary purchases of
#     it (the bundle generates a member purchase per product), so they are already inside the
#     product's own purchase scope.
#
# Not covered here: reachability through rich content. A version whose rich content embeds
# only some of its files does not deliver the others, so this count is an upper bound for a
# file that is not embedded anywhere. That gap is documented on the issue rather than guessed
# at here.
class ProductFileBuyerCountsService
  def initialize(product:)
    @product = product
  end

  # Public: { product_file.external_id => Integer }
  def counts_by_external_id
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

  private
    attr_reader :product

    def alive_files
      @alive_files ||= product.product_files.alive.in_order.includes(:base_variants).to_a
    end

    def buyers
      @buyers ||= product.sales
        .successful_or_preorder_authorization_successful_and_not_refunded_or_chargedback
    end

    def buyers_count
      @buyers_count ||= buyers.count
    end

    # One query for every variant-scoped file on the page: a purchase is counted once per
    # file even when it holds more than one of that file's variants.
    def variant_scoped_counts(files)
      scoped_file_ids = files.reject { _1.base_variants.empty? }.map(&:id)
      return {} if scoped_file_ids.empty?

      BaseVariantsPurchase
        .joins("INNER JOIN base_variants_product_files ON base_variants_product_files.base_variant_id = base_variants_purchases.base_variant_id")
        .where(base_variants_product_files: { product_file_id: scoped_file_ids })
        .where(purchase_id: buyers.select(:id))
        .group("base_variants_product_files.product_file_id")
        .distinct
        .count(:purchase_id)
    end
end
