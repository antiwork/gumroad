# frozen_string_literal: true

class Checkout::DiscountCollectionsPresenter
  include CheckoutDashboardHelper
  def initialize(pundit_user:, discount_collections: nil, pagination: nil)
    @pundit_user = pundit_user
    @discount_collections = discount_collections
    @pagination = pagination
  end

  def discount_collection_props(discount_collection)
    {
      id: discount_collection.external_id,
      name: discount_collection.name,
      description: discount_collection.description,
      offer_codes_count: discount_collection.offer_codes_count,
      total_uses: discount_collection.total_uses,
      total_revenue_cents: discount_collection.total_revenue_cents,
      created_at: discount_collection.created_at.iso8601,
      can_update: Pundit.policy!(@pundit_user, [:checkout, discount_collection]).update?,
      can_destroy: Pundit.policy!(@pundit_user, [:checkout, discount_collection]).destroy?,
      has_defaults: discount_collection.has_defaults?,
      defaults: {
        discount_type: discount_collection.default_discount_type,
        discount_value: discount_collection.default_discount_value,
        max_purchase_count: discount_collection.default_max_purchase_count,
        valid_at: discount_collection.default_valid_at&.iso8601,
        expires_at: discount_collection.default_expires_at&.iso8601,
        minimum_quantity: discount_collection.default_minimum_quantity,
        duration_in_billing_cycles: discount_collection.default_duration_in_billing_cycles,
        minimum_amount_cents: discount_collection.default_minimum_amount_cents
      }
    }
  end

  def discount_collections_props
    {
      pages:,
      pagination: @pagination || {},
      discount_collections: @discount_collections ? @discount_collections.map { discount_collection_props(_1) } : [],
      products: @pundit_user.seller.products.visible.map do |product|
        {
          id: product.external_id,
          name: product.name,
          archived: product.archived?,
          currency_type: product.price_currency_type,
          url: product.long_url,
          is_tiered_membership: product.is_tiered_membership?,
        }
      end,
    }
  end
end
