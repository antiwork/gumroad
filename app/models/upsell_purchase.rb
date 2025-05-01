# frozen_string_literal: true

class UpsellPurchase < ApplicationRecord
  belongs_to :purchase
  belongs_to :upsell

  belongs_to :selected_product, class_name: "Link", optional: true
  belongs_to :upsell_variant, optional: true

  validates :purchase, presence: true, uniqueness: true
  validates_presence_of :upsell

  validate :upsell_must_belong_to_purchase_product
  validate :must_have_upsell_variant_for_upsell

  def as_json
    {
      name: upsell.name,
      discount: purchase.original_offer_code&.displayed_amount_off(purchase.link.price_currency_type, with_symbol: true),
      selected_product: selected_product&.name,
      selected_version: upsell_variant&.selected_variant&.name,
    }
  end

  private
    def upsell_must_belong_to_purchase_product
      if purchase.link != upsell.product
        errors.add(:base, "The upsell must belong to the product being purchased.")
      end
    end

    def must_have_upsell_variant_for_upsell
      if !upsell.cross_sell? && upsell_variant.blank?
        errors.add(:base, "The upsell purchase must have an associated upsell variant.")
      end
    end
end
