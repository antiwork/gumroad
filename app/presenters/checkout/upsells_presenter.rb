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
      products: pundit_user.seller.products
        .visible_and_not_archived
        .map { product_props(_1) }
    }
  end

  private
    def product_props(product)
      {
        id: product.external_id,
        name: product.name,
        has_multiple_versions: product.alive_variants.limit(2).count > 1,
        native_type: product.native_type
      }
    end
end
