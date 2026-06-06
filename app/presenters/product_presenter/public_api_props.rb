# frozen_string_literal: true

# Public, unauthenticated, read-only JSON representation of a product —
# the documented payload returned by `GET /l/:permalink.json`.
#
# This is the read/display counterpart to the seller-facing product page: it
# exposes the same public information the rendered HTML page shows (price,
# covers, description, reviews, variants, social proof) so creators can build
# their own storefronts, embeds, and widgets that stay in sync.
#
# Hard rules:
#   * PUBLIC — never include buyer-specific, seller-private, or admin fields
#     (purchase/buyer state, analytics, can_edit, compliance internals).
#   * Respects creator privacy toggles — `sales_count` is only present when
#     the creator has `should_show_sales_count?` enabled, mirroring the page.
#   * Stable, versioned shape (`api_version`) so integrators can depend on it.
class ProductPresenter::PublicApiProps
  include Rails.application.routes.url_helpers
  include ProductsHelper
  include CurrencyHelper

  # Bump when the public shape changes in a backwards-incompatible way.
  API_VERSION = 1

  def initialize(product:)
    @product = product
    @seller = product.user
  end

  def props
    {
      api_version: API_VERSION,

      # Identity
      id: product.external_id,
      permalink: product.unique_permalink,
      name: product.name,
      native_type: product.native_type,
      url: product.long_url,
      thumbnail_url: product.thumbnail&.alive&.url,
      created_at: product.created_at&.iso8601,
      updated_at: product.updated_at&.iso8601,

      # Seller (public author byline only — no email/PII)
      seller: UserPresenter.new(user: seller).author_byline_props,

      # Pricing
      price_cents: product.price_cents,
      currency_code: product.price_currency_type.downcase,
      price_formatted: product.price_formatted_verbose,
      is_pay_what_you_want: product.customizable_price?,
      suggested_price_cents: product.customizable_price? ? product.suggested_price_cents : nil,
      is_recurring_billing: product.is_recurring_billing,
      is_tiered_membership: product.is_tiered_membership,
      recurrences: product.is_recurring_billing ? product.recurrences : nil,
      free_trial: free_trial_props,

      # Content
      description_html: product.html_safe_description,
      summary: product.custom_summary.presence,
      covers: product.display_asset_previews.as_json,
      attributes: attributes_props,

      # Reviews / social proof (respect creator toggles)
      ratings: product.display_product_reviews? ? product.rating_stats : nil,
      sales_count: product.should_show_sales_count? ? product.successful_sales_count : nil,

      # Variants / options / inventory
      options: product.options,
      quantity_remaining: product.remaining_for_sale_count,
      is_quantity_enabled: product.quantity_enabled,
      is_sales_limited: product.max_purchase_count?,

      # Policies & meta
      is_published: !product.draft && product.alive?,
      is_physical: product.is_physical,
      refund_policy: refund_policy_props,
    }
  end

  private
    attr_reader :product, :seller

    def free_trial_props
      return nil unless product.free_trial_enabled?

      {
        duration: {
          unit: product.free_trial_duration_unit,
          amount: product.free_trial_duration_amount,
        },
      }
    end

    def attributes_props
      product.custom_attributes.filter_map do |attr|
        { name: attr["name"], value: attr["value"] } if attr["name"].present? || attr["value"].present?
      end + product.file_info_for_product_page.map { |k, v| { name: k.to_s, value: v } }
    end

    def refund_policy_props
      policy =
        if seller.account_level_refund_policy_enabled?
          seller.refund_policy
        elsif product.product_refund_policy_enabled?
          product.product_refund_policy
        end
      return nil if policy.nil?

      {
        title: policy.title,
        fine_print: policy.fine_print.presence,
        updated_at: policy.updated_at&.to_date&.iso8601,
      }
    end
end
