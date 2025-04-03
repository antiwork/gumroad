# frozen_string_literal: true

class BundleProduct < ApplicationRecord
  include Deletable, ExternalId

  has_paper_trail

  belongs_to :bundle, class_name: "Link"
  belongs_to :product, class_name: "Link"
  belongs_to :variant, class_name: "BaseVariant", optional: true

  validate :product_belongs_to_bundle_seller
  validate :versioned_product_has_variant
  validate :variant_belongs_to_product
  validate :product_is_not_bundle
  validate :product_is_not_subscription
  validate :product_is_not_call
  validate :is_not_duplicate
  validate :bundle_is_bundle_product
  validate :product_is_eligible_for_installment_plan

  attribute :quantity, default: 1

  scope :in_order, -> { order(position: :asc) }

  def standalone_price_cents
    (product.price_cents + (variant&.price_difference_cents || 0)) * quantity
  end

  def eligible_for_installment_plans?
    # This method determines if a product can be included in a bundle that
    # offers installment plans. While it currently delegates to the product's
    # own eligibility check, the criteria may differ in the future. For
    # example, while installment plans explicitly reject "pay what you want"
    # pricing, but a PWYW product could still be part of a fixed-price bundle
    # with installment plans.
    product.eligible_for_installment_plans?
  end

  private
    def product_belongs_to_bundle_seller
      if bundle.user != product.user
        errors.add(:base, "The product must belong to the bundle's seller")
      end
    end

    def versioned_product_has_variant
      if (product.skus_enabled && product.skus.alive.not_is_default_sku.count > 1) || product.alive_variants.present?
        if variant.blank?
          errors.add(:base, "Bundle product must have variant specified for versioned product")
        end
      end
    end

    def variant_belongs_to_product
      if variant.present? && variant.link != product
        errors.add(:base, "The bundle product's variant must belong to its product")
      end
    end

    def product_is_not_bundle
      if product.is_bundle
        errors.add(:base, "A bundle product cannot be added to a bundle")
      end
    end

    def product_is_not_subscription
      if product.is_recurring_billing
        errors.add(:base, "A subscription product cannot be added to a bundle")
      end
    end

    def product_is_not_call
      if product.native_type == Link::NATIVE_TYPE_CALL
        errors.add(:base, "A call product cannot be added to a bundle")
      end
    end

    def is_not_duplicate
      if bundle.bundle_products.where(product_id:).where.not(id:).present?
        errors.add(:base, "Product is already in bundle")
      end
    end

    def bundle_is_bundle_product
      if bundle.not_is_bundle?
        errors.add(:base, "Bundle products can only be added to bundles")
      end
    end

    def product_is_eligible_for_installment_plan
      return if bundle.installment_plan.blank?
      return if eligible_for_installment_plans?

      errors.add(:base, "Installment plan is not available for the bundled product: #{product.name}")
    end
end
