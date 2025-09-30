# frozen_string_literal: true

class Upsell < ApplicationRecord
  include Deletable, ExternalId, FlagShihTzu, Upsell::Sorting

  has_paper_trail

  has_flags 1 => :replace_selected_products,
            2 => :is_content_upsell,
            :column => "flags",
            :flag_query_mode => :bit_operator,
            check_for_column: false

  belongs_to :seller, class_name: "User"
  # For a cross-sell, this is the product that will be added to the cart if the buyer accepts the offer.
  # For an upsell, this is the product on which the buyer is offered a version change.
  belongs_to :product, class_name: "Link"
  belongs_to :variant, class_name: "BaseVariant", optional: true
  belongs_to :offer_code, optional: true, autosave: true

  has_many :upsell_variants, autosave: true
  has_many :upsell_purchases
  has_many :purchases, through: :upsell_purchases
  has_many :purchases_that_count_towards_volume, -> { counts_towards_volume }, through: :upsell_purchases, source: :purchase
  has_and_belongs_to_many :selected_products, class_name: "Link", join_table: "upsells_selected_products", association_foreign_key: "selected_product_id"

  validates_presence_of :seller, :product
  validates_presence_of :name, unless: :is_content_upsell?

  validate :selected_products_belong_to_seller
  validate :product_belongs_to_seller
  validate :variant_belongs_to_product
  validate :offer_code_belongs_to_seller_and_product
  validate :has_one_upsell_variant_per_selected_variant
  validate :has_one_upsell_per_product
  validate :product_is_not_call

  scope :upsell, -> { where(cross_sell: false) }
  scope :cross_sell, -> { where(cross_sell: true) }
  scope :available_to_customers, -> { alive.where(paused: false) }

  def as_json(options = {})
    {
      id: external_id,
      name:,
      cross_sell:,
      replace_selected_products:,
      universal:,
      text:,
      description:,
      paused:,
      product: {
        id: product.external_id,
        name: product.name,
        currency_type: product.price_currency_type.downcase || "usd",
        variant: variant.present? ? {
          id: variant.external_id,
          name: variant.name
        } : nil,
      },
      discount: offer_code&.discount,
      selected_products: selected_products.map do |product|
        {
          id: product.external_id,
          name: product.name,
        }
      end,
      upsell_variants: upsell_variants.alive.map do |upsell_variant|
        {
          id: upsell_variant.external_id,
          selected_variant: {
            id: upsell_variant.selected_variant.external_id,
            name: upsell_variant.selected_variant.name
          },
          offered_variant: {
            id: upsell_variant.offered_variant.external_id,
            name: upsell_variant.offered_variant.name
          },
        }
      end,
    }
  end

  private
    def selected_products_belong_to_seller
      if selected_products.any? { _1.user != seller }
        errors.add(:base, "All offered products must belong to the current seller.")
      end
    end

    def product_belongs_to_seller
      if product.user != seller
        errors.add(:base, "The offered product must belong to the current seller.")
      end
    end

    def variant_belongs_to_product
      if variant.present? && variant.link != product
        errors.add(:base, "The offered variant must belong to the offered product.")
      end
    end

    def offer_code_belongs_to_seller_and_product
      if offer_code.present? && (offer_code.user != seller || offer_code.products.exclude?(product))
        errors.add(:base, "The offer code must belong to the seller and the offered product.")
      end
    end

    def has_one_upsell_variant_per_selected_variant
      if upsell_variants.group(:selected_variant_id).count.values.any? { |count| count > 1 }
        errors.add(:base, "The upsell cannot have more than one upsell variant per selected variant.")
      end
    end

    def has_one_upsell_per_product
      if !cross_sell? && deleted_at.blank? && seller.upsells.upsell.alive.where(product:).where.not(id:).any?
        errors.add(:base, "You can only create one upsell per product.")
      end
    end

    def product_is_not_call
      if product.native_type == Link::NATIVE_TYPE_CALL
        errors.add(:base, "Calls cannot be offered as upsells.")
      end
    end
end
