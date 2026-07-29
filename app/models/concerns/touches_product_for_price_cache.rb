# frozen_string_literal: true

# Bumps the product's `updated_at` when a row that feeds the product's *displayed price*
# changes. `Pages::ProfileData.cache_key` keys the cached storefront payload on
# `seller.products.cache_key_with_version` (i.e. MAX(links.updated_at)), while the payload's
# `price` resolves through the `prices` and variant rows — so a price write that never
# touches `links` leaves the storefront serving the old price until an unrelated product edit
# or a deploy moves the key.
#
# `belongs_to ..., touch: true` is the right tool when the association points straight at the
# product (see `AssetPreview`, `Thumbnail`). Include this instead when the product is one or
# more hops away, since Rails only touches the immediate association.
#
# Safe against write loops: `Link`'s own `after_update :invalidate_cache` subtracts
# `PURCHASE_PROPERTIES` (`["updated_at"]`), so a timestamp-only save fires nothing further.
module TouchesProductForPriceCache
  extend ActiveSupport::Concern

  included do
    after_commit :touch_product_for_price_cache
  end

  private
    def touch_product_for_price_cache
      # `previous_changes` is empty on a no-op save, and a touch that only re-stamped
      # `updated_at` is not a price change worth rebuilding the storefront for.
      return if previous_changes.blank? || previous_changes.keys == ["updated_at"]

      link&.touch
    rescue ActiveRecord::RecordNotFound
      # The product can be hard-deleted out from under an in-flight variant/price write.
      nil
    end
end
