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
      products: pundit_user.seller.products.visible.map do |product|
        {
          id: product.external_id,
          name: product.name,
          archived: product.archived?,
          currency_type: product.price_currency_type,
          url: product.long_url,
          is_tiered_membership: product.is_tiered_membership?,
          is_recurring_billing: product.is_recurring_billing?,
        }
      end,
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
      products: offer_code.universal ? nil : offer_code.products.map do |product|
        {
          id: product.external_id,
          name: product.name,
          archived: product.archived?,
          url: product.long_url,
          currency_type: product.price_currency_type,
          is_tiered_membership: product.is_tiered_membership?,
          is_recurring_billing: product.is_recurring_billing?,
        }
      end,
      limit: offer_code.max_purchase_count,
      currency_type: offer_code.currency_type || Currency::USD,
      valid_at: offer_code.valid_at,
      expires_at: offer_code.expires_at,
      minimum_quantity: offer_code.minimum_quantity,
      duration_in_billing_cycles: offer_code.duration_in_billing_cycles,
      minimum_amount_cents: offer_code.minimum_amount_cents,
    }
  end
end
