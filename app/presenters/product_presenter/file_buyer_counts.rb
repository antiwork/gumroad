# frozen_string_literal: true

# How many buyers would lose download access if this file became read-only
# (gumroad-private#2918, the confirmation the retroactive toggle decided in #2916 needs).
#
# The number gates a destructive save, so it has to count buyers who can actually
# REACH the file rather than the product's sale count. Those differ in two ways:
#
# - A file embedded in per-version content is reachable only by buyers holding a
#   version that carries it (`BaseVariant#product_files`, the join table written on
#   every product save — see Product::VariantCategoryUpdaterService). A file with no
#   version scoping at all — the shared-content case, which is the default — is
#   reachable by every buyer of the product.
# - A bundle purchase is its own purchase row on each member product, so the purchase
#   count already includes the buyers who came in through a bundle.
#
# Deliberately NOT built on `ProductFile#as_json`: that serialization is shared with
# the existing-files picker and the product page's own specs, so the count is merged
# into the editor's props path only (ProductPresenter#edit_props).
class ProductPresenter::FileBuyerCounts
  # Buyers holding access today: the charged and gift-receiver success states, minus
  # fully refunded and unreversed-chargebacked rows. Same family as
  # Purchase.successful_or_preorder_authorization_successful_and_not_refunded_or_chargedback,
  # plus the gift-receiver rows, which are the ones holding the access in a gifted sale.
  REACHABLE_PURCHASE_STATES = Purchase::ALL_SUCCESS_STATES

  def initialize(product:)
    @product = product
  end

  # @return [Hash{String => Integer}] product file external id => buyer count
  def props
    counts = files.index_with { |file| file.base_variant_ids.empty? ? total_buyer_count : version_scoped_counts.fetch(file.id, 0) }
    counts.transform_keys { |file| file.external_id }
  end

  private
    attr_reader :product

    def files
      @files ||= product.product_files.alive.in_order.to_a
    end

    def version_scoped_files
      @version_scoped_files ||= files.reject { _1.base_variant_ids.empty? }
    end

    def buyer_scope
      @buyer_scope ||=
        product.sales
          .where(purchase_state: REACHABLE_PURCHASE_STATES)
          .not_fully_refunded
          .not_chargedback_or_chargedback_reversed
    end

    def total_buyer_count
      @total_buyer_count ||= buyer_scope.distinct.count
    end

    # One grouped query for every version-scoped file on the page: buyers per file,
    # counted distinctly so a buyer holding two of a file's versions (two categories)
    # is not counted twice.
    def version_scoped_counts
      @version_scoped_counts ||=
        if version_scoped_files.empty?
          {}
        else
          buyer_scope
            .joins(:base_variants_purchases)
            .joins("INNER JOIN base_variants_product_files bvpf ON bvpf.base_variant_id = base_variants_purchases.base_variant_id")
            .where("bvpf.product_file_id IN (?)", version_scoped_files.map(&:id))
            .group("bvpf.product_file_id")
            .distinct
            .count("purchases.id")
        end
    end
end
