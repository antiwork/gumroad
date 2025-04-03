# frozen_string_literal: true

class WishlistProduct < ApplicationRecord
  include ExternalId
  include Deletable

  WISHLIST_PRODUCT_LIMIT = 100

  belongs_to :wishlist
  belongs_to :product, class_name: "Link"
  belongs_to :variant, class_name: "BaseVariant", optional: true

  scope :available_to_buy, -> { joins(product: :user).merge(Link.alive).merge(User.not_suspended) }

  validates :product_id, uniqueness: { scope: [:wishlist_id, :variant_id, :recurrence, :deleted_at] }
  validates :recurrence, inclusion: { in: BasePrice::Recurrence::ALLOWED_RECURRENCES }, if: -> { product&.is_recurring_billing }
  validates :recurrence, absence: true, unless: -> { product&.is_recurring_billing }
  validates :quantity, numericality: { greater_than: 0 }
  validates :quantity, numericality: { equal_to: 1 }, unless: -> { product&.quantity_enabled }
  validates :rent, absence: true, unless: -> { product&.rentable? }
  validates :rent, presence: true, unless: -> { product&.buyable? }

  validate :versioned_product_has_variant
  validate :variant_belongs_to_product
  validate :wishlist_product_limit, on: :create

  attribute :quantity, default: 1
  attribute :rent, default: false

  after_create :update_wishlist_recommendable
  after_update :update_wishlist_recommendable, if: :saved_change_to_deleted_at?

  private
    def update_wishlist_recommendable
      wishlist.update_recommendable
    end

    def versioned_product_has_variant
      if (product.skus_enabled && product.skus.alive.not_is_default_sku.count > 1) || product.alive_variants.present?
        if variant.blank?
          errors.add(:base, "Wishlist product must have variant specified for versioned product")
        end
      end
    end

    def variant_belongs_to_product
      if variant.present? && variant.link != product
        errors.add(:base, "The wishlist product's variant must belong to its product")
      end
    end

    def wishlist_product_limit
      if wishlist.alive_wishlist_products.count >= WISHLIST_PRODUCT_LIMIT
        errors.add(:base, "A wishlist can have at most #{WISHLIST_PRODUCT_LIMIT} products")
      end
    end
end
