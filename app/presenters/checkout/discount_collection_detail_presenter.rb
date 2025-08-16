# frozen_string_literal: true

class Checkout::DiscountCollectionDetailPresenter
  include CheckoutDashboardHelper

  def initialize(pundit_user:, discount_collection:, offer_codes:)
    @pundit_user = pundit_user
    @discount_collection = discount_collection
    @offer_codes = offer_codes
  end

  def discount_collection_props
    {
      id: @discount_collection.external_id,
      name: @discount_collection.name,
      description: @discount_collection.description,
      has_defaults: @discount_collection.has_defaults?,
      defaults: {
        discount_type: @discount_collection.default_discount_type,
        discount_value: @discount_collection.default_discount_value,
        max_purchase_count: @discount_collection.default_max_purchase_count,
        valid_at: @discount_collection.default_valid_at&.iso8601,
        expires_at: @discount_collection.default_expires_at&.iso8601,
        minimum_quantity: @discount_collection.default_minimum_quantity,
        duration_in_billing_cycles: @discount_collection.default_duration_in_billing_cycles,
        minimum_amount_cents: @discount_collection.default_minimum_amount_cents
      }
    }
  end

  def offer_codes_props
    @offer_codes.map { offer_code_props(_1) }
  end

  def offer_code_props(offer_code)
    {
      id: offer_code.external_id,
      name: offer_code.name,
      code: offer_code.code,
      discount: offer_code.amount_cents.present? ? { type: "cents", value: offer_code.amount_cents } : { type: "percent", value: offer_code.amount_percentage },
      max_purchase_count: offer_code.max_purchase_count,
      total_uses: offer_code.purchases.sum(:quantity),
      revenue_cents: offer_code.purchases.sum(:price_cents),
      valid_at: offer_code.valid_at&.iso8601,
      expires_at: offer_code.expires_at&.iso8601,
      created_at: offer_code.created_at.iso8601,
      can_update: Pundit.policy!(@pundit_user, [:checkout, offer_code]).update?,
      can_destroy: Pundit.policy!(@pundit_user, [:checkout, offer_code]).destroy?
    }
  end
end
