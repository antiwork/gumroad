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

  def initialize(product:, seller_custom_domain_url: nil)
    @product = product
    @seller = product.user
    @seller_custom_domain_url = seller_custom_domain_url
  end

  def props
    {
      api_version: API_VERSION,

      # Identity
      id: product.external_id,
      permalink: product.general_permalink,
      name: product.name,
      native_type: product.native_type,
      url: product.long_url,
      thumbnail_url: product.thumbnail&.alive&.url,
      created_at: product.created_at&.iso8601,
      updated_at: product.updated_at&.iso8601,

      # Seller (public author byline only — no email/PII)
      seller: seller_props,

      # Pricing
      price_cents: product.price_cents,
      currency_code: product.price_currency_type.downcase,
      price_formatted: product.price_formatted_verbose,
      is_pay_what_you_want: product.customizable_price?,
      suggested_price_cents: product.customizable_price? ? product.suggested_price_cents : nil,
      is_recurring_billing: product.is_recurring_billing,
      is_tiered_membership: product.is_tiered_membership,
      recurrences: product.is_recurring_billing ? product.recurrences.as_json : nil,
      free_trial: free_trial_props,

      # Content
      description_html: product.html_safe_description,
      summary: product.custom_summary.presence,
      covers: product.display_asset_previews.as_json,
      attributes: attributes_props,

      # Reviews / social proof (respect creator toggles)
      ratings: product.display_product_reviews? ? product.rating_stats : nil,
      sales_count: ProductPresenter.cached_sales_count(product),

      # Variants / options / inventory
      options: product.options.as_json,
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
    attr_reader :product, :seller, :seller_custom_domain_url

    # Always an object (never null), mirroring the documented shape. Falls back
    # to a username-less byline when the seller has no public profile URL, and
    # honors the request's custom domain so the profile_url matches the byline
    # the rendered product page shows on a seller custom domain.
    def seller_props
      UserPresenter.new(user: seller).author_byline_props(custom_domain_url: seller_custom_domain_url) || {
        id: seller.external_id,
        name: seller.name_or_username,
        avatar_url: seller.avatar_url,
        profile_url: seller_profile_url,
        is_verified: !!seller.verified,
      }
    end

    # nil-safe: a seller with no username has no subdomain, so profile_url would
    # raise on URI(nil) unless a custom domain is present.
    def seller_profile_url
      return seller.profile_url(custom_domain_url: seller_custom_domain_url) if seller_custom_domain_url.present?

      seller.subdomain_with_protocol && seller.profile_url
    end

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
        # Mirror the rendered product page, which wraps the fine print with
        # simple_format (ProductPresenter::ProductProps) and renders it as HTML.
        fine_print: policy.fine_print.present? ? ActionController::Base.helpers.simple_format(policy.fine_print) : nil,
        updated_at: policy.updated_at&.to_date&.iso8601,
      }
    end
end
