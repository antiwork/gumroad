# frozen_string_literal: true

class Checkout::DiscountsPresenter
  include CheckoutDashboardHelper

  BLACK_FRIDAY_CODE_NAME = "Black Friday 2025"

  attr_reader :pundit_user, :offer_codes, :pagination

  def initialize(pundit_user:, offer_codes: [], pagination: nil)
    @pundit_user = pundit_user
    @offer_codes = offer_codes
    @pagination = pagination
  end

  def discounts_props
    {
      pages:,
      pagination:,
      offer_codes: offer_codes.map { offer_code_props(_1) },
      products: product_props_by_product,
      show_black_friday_banner: Feature.active?(:black_friday_seller_banner),
      black_friday_code: SearchProducts::BLACK_FRIDAY_CODE,
      black_friday_code_name: BLACK_FRIDAY_CODE_NAME
    }
  end

  def offer_code_props(offer_code)
    {
      id: offer_code.external_id,
      can_update: Pundit.policy!(pundit_user, [:checkout, offer_code]).update?,
      name: offer_code.name.presence || "",
      code: offer_code.code,
      discount: offer_code.amount_cents.present? ? { type: "cents", value: offer_code.amount_cents } : { type: "percent", value: offer_code.amount_percentage },
      products: offer_code.universal ? nil : offer_code.products.map { product_props_for(_1) },
      excluded_products: offer_code.universal ? offer_code.excluded_products.map { product_props_for(_1) } : [],
      limit: offer_code.max_purchase_count,
      currency_type: offer_code.currency_type || Currency::USD,
      valid_at: offer_code.valid_at,
      expires_at: offer_code.expires_at,
      minimum_quantity: offer_code.minimum_quantity,
      duration_in_billing_cycles: offer_code.duration_in_billing_cycles,
      minimum_amount_cents: offer_code.minimum_amount_cents,
      once_per_cart: offer_code.is_cents? && offer_code.once_per_cart?,
      existing_customers_only: offer_code.existing_customers_only?,
      ownership_products: offer_code.ownership_products.map { product_props_for(_1) },
      ownership_duration_tiers: offer_code.normalized_ownership_duration_tiers,
      option_ids: offer_code.live_scoped_variants.map(&:external_id),
    }
  end

  private
    def product_props_for(product)
      {
        id: product.external_id,
        name: product.name,
        archived: product.archived?,
        url: product.long_url,
        currency_type: product.price_currency_type,
        is_tiered_membership: product.is_tiered_membership?,
        is_recurring_billing: product.is_recurring_billing?,
      }
    end

    # The form offers a product's options as discount scope, so the options travel with the
    # products it already lists. Preload both option shapes: `Link#options` queries per product
    # when the association is not loaded, and SKUs are not `alive_variants`.
    def product_props_by_product
      pundit_user.seller.products.visible.includes(:alive_variants, :variant_categories_alive, :skus_alive_not_default).map do |product|
        props = product_props_for(product)
        options = product.options
        props[:options] = options.map { { id: _1[:id], name: _1[:name] } } if options.any?
        props
      end
    end
end
