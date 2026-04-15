# frozen_string_literal: true

# Used to generate the product page for a purchase (e.g. /purchases/:id/product)
# for fighting chargebacks
# Similar with app/presenters/product_presenter.rb
# Attempts to retrieve the product description, refund policy, and pricing, at the
# time of purchase, via versioning
#
class PurchaseProductPresenter
  include Rails.application.routes.url_helpers

  attr_reader :product, :purchase, :request

  def initialize(purchase)
    @purchase = purchase
    @product = purchase.link.paper_trail.version_at(purchase.created_at) || purchase.link
  end

  def product_props
    purchase_refund_policy = purchase.purchase_refund_policy

    {
      product: {
        name: product.name,
        seller: UserPresenter.new(user: product.user).author_byline_props,
        covers: display_asset_previews.as_json,
        main_cover_id: display_asset_previews.first&.guid,
        thumbnail_url: product.thumbnail&.alive&.url,
        quantity_remaining: product.remaining_for_sale_count,
        currency_code: product.price_currency_type.downcase,
        long_url: product.long_url,
        is_sales_limited: product.max_purchase_count?,
        price_cents: product.price_cents,
        rental_price_cents: product.rental_price_cents,
        pwyw: product.customizable_price ? { suggested_price_cents: product.suggested_price_cents } : nil,
        ratings: product.display_product_reviews? ? product.rating_stats : nil,
        is_legacy_subscription: product.is_legacy_subscription?,
        is_tiered_membership: product.is_tiered_membership,
        is_recurring_billing: product.is_recurring_billing,
        is_physical: product.is_physical,
        custom_view_content_button_text: product.custom_view_content_button_text.presence,
        custom_button_text_option: product.custom_button_text_option,
        is_multiseat_license: product.is_tiered_membership && product.is_multiseat_license,
        permalink: product.unique_permalink,
        preorder: product.is_in_preorder_state ? { release_date: product.preorder_link.release_at } : nil,
        description_html: product.html_safe_description,
        is_compliance_blocked: false,
        is_published: !product.draft && product.alive?,
        duration_in_months: product.duration_in_months,
        rental: product.rental,
        is_stream_only: product.has_stream_only_files?,
        is_quantity_enabled: product.quantity_enabled,
        sales_count:,
        free_trial: product.free_trial_enabled ? {
          duration: {
            unit: product.free_trial_duration_unit,
            amount: product.free_trial_duration_amount
          }
        } : nil,
        summary: product.custom_summary.presence,
        attributes: product.custom_attributes.filter_map do |attr|
          { name: attr["name"], value: attr["value"] } if attr["name"].present? || attr["value"].present?
        end + product.file_info_for_product_page.map { |k, v| { name: k.to_s, value: v } },
        recurrences: product.recurrences,
        options:,
        analytics: product.analytics_data,
        has_third_party_analytics: false,
        ppp_details: nil,
        can_edit: false,
        refund_policy: purchase_refund_policy.present? ? {
          title: purchase_refund_policy.title,
          fine_print: purchase_refund_policy.fine_print.present? ? ActionController::Base.helpers.simple_format(purchase_refund_policy.fine_print) : nil,
          updated_at: purchase_refund_policy.updated_at,
        } : nil
      },
      discount_code: nil,
      purchase: nil,
    }
  end

  def display_asset_previews
    product.display_asset_previews
      .unscoped
      .where(link_id: product.id)
      .where("created_at < ?", purchase.created_at)
      .where("deleted_at IS NULL OR deleted_at > ?", purchase.created_at)
      .order(:position)
  end

  # Similar to Link#options, only that it builds the options that were available at the time of purchase
  def options
    product.skus_enabled ? sku_options : variant_category_options
  end

  def sales_count
    return unless product.should_show_sales_count?

    product.successful_sales_count
  end

  def sku_options
    product.skus
      .not_is_default_sku
      .where("created_at < ?", purchase.created_at)
      .where("deleted_at IS NULL OR deleted_at > ?", purchase.created_at)
      .map(&:to_option_for_product)
  end

  def variant_category_options
    first_variant_category = product.variant_categories.where("variant_categories.deleted_at IS NULL OR deleted_at > ?", purchase.created_at).first
    return [] unless first_variant_category

    first_variant_category.variants
      .where("created_at < ?", purchase.created_at)
      .where("deleted_at IS NULL OR deleted_at > ?", purchase.created_at)
      .in_order
      .map(&:to_option)
  end
end
