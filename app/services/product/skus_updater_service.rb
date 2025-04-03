# frozen_string_literal: true

class Product::SkusUpdaterService
  include CurrencyHelper

  attr_reader :product, :skus_params

  delegate :skus, :variant_categories, :price_currency_type, to: :product

  def initialize(product:, skus_params: [])
    @product = product
    @skus_params = skus_params
  end

  def perform
    return skus.not_is_default_sku.alive.map(&:mark_deleted!) if variant_categories.alive.empty?

    previous_skus = skus.alive.to_a
    skus_to_keep = skus.is_default_sku.to_a
    variants_per_category = variant_categories.alive.map { |cat| cat.alive_variants.to_a }
    variants_per_sku = variants_per_category.size > 1 ? variants_per_category.reduce(&:product) : variants_per_category.first.product

    variants_per_sku.map do |variants|
      variants.flatten!
      sku_name = variants.map(&:name).join(" - ")
      sku = variants.map(&:alive_skus).inject(:&).first
      if sku&.alive? && sku.variants.sort == variants.sort
        sku.update!(name: sku_name) if sku.name != sku_name
        skus_to_keep << sku
      else
        sku = skus.build(name: sku_name)
        sku.variants = variants
        sku.save!
      end
    end

    update_from_params!

    (previous_skus - skus_to_keep).map(&:mark_deleted!)
  end

  private
    def update_from_params!
      skus_params.each do |sku_params|
        begin
          sku = skus.find_by_external_id!(sku_params[:id])
        rescue ActiveRecord::RecordNotFound
          product.errors.add(:base, "Please provide valid IDs for all SKUs.")
          raise Link::LinkInvalid
        end
        price_difference_cents = string_to_price_cents(price_currency_type, sku_params[:price_difference])
        max_purchase_count = sku_params[:max_purchase_count]
        custom_sku = sku_params[:custom_sku] || sku.custom_sku
        if sku.price_difference_cents != price_difference_cents || sku.max_purchase_count != max_purchase_count || sku.custom_sku != custom_sku
          sku.update!(
            price_difference_cents:,
            max_purchase_count:,
            custom_sku:,
          )
        end
      end
    end
end
