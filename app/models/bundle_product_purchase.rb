# frozen_string_literal: true

class BundleProductPurchase < ApplicationRecord
  belongs_to :bundle_purchase, class_name: "Purchase", foreign_key: :bundle_purchase_id
  belongs_to :product_purchase, class_name: "Purchase", foreign_key: :product_purchase_id

  validate :purchases_must_have_same_seller
  validate :product_purchase_cannot_be_bundle_purchase

  private
    def purchases_must_have_same_seller
      if bundle_purchase.seller != product_purchase.seller
        errors.add(:base, "Seller must be the same for bundle and product purchases")
      end
    end

    def product_purchase_cannot_be_bundle_purchase
      if product_purchase.link.is_bundle?
        errors.add(:base, "Product purchase cannot be a bundle purchase")
      end
    end
end
