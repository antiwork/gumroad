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

    purchase.quantity = new_quantity
    purchase.variant_attributes = new_variants
    purchase.save!
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
end
