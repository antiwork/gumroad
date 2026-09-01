# frozen_string_literal: true

class Checkout::UpsellsPresenter
  include CheckoutDashboardHelper

  attr_reader :pundit_user, :upsells, :pagination

  def initialize(pundit_user:, upsells:, pagination:)
    @pundit_user = pundit_user
    @upsells = upsells
    @pagination = pagination
  end

  def upsells_props
    {
      pages:,
      upsells: upsells.includes(
          :product,
          :variant,
          :offer_code,
          :selected_products,
          upsell_variants: [:selected_variant, :offered_variant]
        ).map(&:as_json),
      pagination:,
      products: product_props
    }
  end

  private
    def product_props
      products = pundit_user.seller.products.visible_and_not_archived.to_a
      product_ids_with_multiple_versions = Variant.alive
        .joins(:variant_category)
        .merge(VariantCategory.alive)
        .where(variant_categories: { link_id: products.map(&:id) })
        .group("variant_categories.link_id")
        .having("COUNT(base_variants.id) > 1")
        .pluck("variant_categories.link_id")
        .to_set

      products.map do |product|
        {
          id: product.external_id,
          name: product.name,
          has_multiple_versions: product_ids_with_multiple_versions.include?(product.id),
          native_type: product.native_type
        }
      end
    end
end
