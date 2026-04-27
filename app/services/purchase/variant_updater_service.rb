# frozen_string_literal: true

class Purchase::VariantUpdaterService
  attr_reader :purchase, :variant_id, :new_variant, :product, :new_quantity

  def initialize(purchase:, variant_id:, quantity:)
    @purchase = purchase
    @variant_id = variant_id
    @new_quantity = quantity
  end

  def perform
    @product = purchase.link

    if product.skus_enabled?
      @new_variant = product.skus.find_by_external_id!(variant_id)
      new_variants = [new_variant]
    else
      @new_variant = Variant.find_by_external_id!(variant_id)
      variant_category = new_variant.variant_category
      if variant_category.link != product
        return false
      end
      new_variants = purchase.variant_attributes.where.not(variant_category_id: variant_category.id).to_a
      new_variants << new_variant
    end

    return false unless new_variants.all? { |variant| sufficient_inventory?(variant, new_quantity - (purchase.variant_attributes == new_variants ? purchase.quantity : 0)) }

    before_counted = purchase.counts_towards_inventory?
    before_variant_ids = purchase.variant_attribute_ids.dup
    before_quantity = purchase.quantity.to_i

    purchase.quantity = new_quantity
    purchase.variant_attributes = new_variants
    purchase.save!

    sync_inventory_counter_cache_for_variant_swap(before_counted, before_variant_ids, before_quantity)

    if purchase.is_gift_sender_purchase?
      Purchase::VariantUpdaterService.new(
        purchase: purchase.gift.giftee_purchase,
        variant_id:,
        quantity: new_quantity
      ).perform
    end
    Purchase::Searchable::VariantAttributeCallbacks.variants_changed(purchase)
    true
  rescue ActiveRecord::RecordNotFound
    false
  end

  private
    def sufficient_inventory?(variant, quantity)
      variant.quantity_left ? variant.quantity_left >= quantity : true
    end

    def sync_inventory_counter_cache_for_variant_swap(before_counted, before_variant_ids, before_quantity)
      after_variant_ids = purchase.variant_attribute_ids
      removed_ids = before_variant_ids - after_variant_ids
      added_ids = after_variant_ids - before_variant_ids

      if before_counted && removed_ids.any? && before_quantity > 0
        BaseVariant.where(id: removed_ids).update_all("sales_count_for_inventory_cache = sales_count_for_inventory_cache - #{before_quantity}")
      end

      if purchase.counts_towards_inventory? && added_ids.any? && before_quantity > 0
        BaseVariant.where(id: added_ids).update_all("sales_count_for_inventory_cache = sales_count_for_inventory_cache + #{before_quantity}")
      end
    end
end
