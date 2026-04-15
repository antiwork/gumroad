# frozen_string_literal: true

class BundlePresenter
  include Rails.application.routes.url_helpers

  attr_reader :bundle

  def initialize(bundle:)
    @bundle = bundle
  end

  def edit_product_props
    shared_props.merge(
      currency_type: bundle.price_currency_type,
      thumbnail: bundle.thumbnail&.alive&.as_json,
      sales_count_for_inventory: bundle.sales_count_for_inventory,
      ratings: bundle.rating_stats,
      refund_policies: bundle.user
        .product_refund_policies
        .for_visible_and_not_archived_products
        .where.not(product_id: bundle.id)
        .order(updated_at: :desc)
        .select("refund_policies.*", "links.name")
        .as_json,
      seller_refund_policy_enabled: bundle.user.account_level_refund_policy_enabled?,
      seller_refund_policy: {
        title: bundle.user.refund_policy.title,
        fine_print: bundle.user.refund_policy.fine_print,
      },
    )
  end

  def edit_content_props
    shared_props.merge(
      products_count: bundle.user.products.alive.not_archived.not_is_recurring_billing.not_is_bundle.not_call.count,
      has_outdated_purchases: bundle.has_outdated_purchases,
    )
  end

  def edit_share_props
    profile_sections = bundle.user.seller_profile_products_sections
    shared_props.merge(
      taxonomies: Discover::TaxonomyPresenter.new.taxonomies_for_nav,
      profile_sections: profile_sections.map do |section|
        {
          id: section.external_id,
          header: section.header || "",
          product_names: section.product_names,
          default: section.add_new_products,
        }
      end,
      currency_type: bundle.price_currency_type,
      sales_count_for_inventory: bundle.sales_count_for_inventory,
      ratings: bundle.rating_stats,
      seller_refund_policy_enabled: bundle.user.account_level_refund_policy_enabled?,
      seller_refund_policy: {
        title: bundle.user.refund_policy.title,
        fine_print: bundle.user.refund_policy.fine_print,
      },
    )
  end

  def self.bundle_product(product:, quantity: 1, selected_variant_id: nil)
    variants = product.variants_or_skus
    ProductPresenter.card_for_web(product:).merge(
      {
        is_quantity_enabled: product.quantity_enabled,
        quantity:,
        price_cents: product.price_cents,
        created_at: product.created_at.iso8601,
        variants: variants.present? ? {
          selected_id: selected_variant_id || variants.first.external_id,
          list: variants.map do |variant|
            {
              id: variant.external_id,
              name: variant.name,
              description: variant.description || "",
              price_difference: variant.price_difference_cents || 0,
            }
          end
        } : nil,
      }
    )
  end

  private
    def refund_policy
      @refund_policy ||= bundle.find_or_initialize_product_refund_policy
    end

    def refund_policy_props
      {
        allowed_refund_periods_in_days: RefundPolicy::ALLOWED_REFUND_PERIODS_IN_DAYS.keys.map do
          {
            key: _1,
            value: RefundPolicy::ALLOWED_REFUND_PERIODS_IN_DAYS[_1]
          }
        end,
        max_refund_period_in_days: refund_policy.max_refund_period_in_days,
        fine_print: refund_policy.fine_print,
        fine_print_enabled: refund_policy.fine_print.present?,
        title: refund_policy.title,
      }
    end

    def shared_props
      collaborator = bundle.collaborator_for_display
      {
        bundle: {
          name: bundle.name,
          description: bundle.description || "",
          custom_permalink: bundle.custom_permalink,
          price_cents: bundle.price_cents,
          customizable_price: !!bundle.customizable_price,
          suggested_price_cents: bundle.suggested_price_cents,
          **ProductPresenter::InstallmentPlanProps.new(product: bundle).props,
          custom_button_text_option: bundle.custom_button_text_option,
          custom_summary: bundle.custom_summary,
          custom_attributes: bundle.custom_attributes,
          max_purchase_count: bundle.max_purchase_count,
          quantity_enabled: bundle.quantity_enabled,
          should_show_sales_count: bundle.should_show_sales_count,
          is_epublication: bundle.is_epublication?,
          product_refund_policy_enabled: bundle.product_refund_policy_enabled?,
          refund_policy: refund_policy_props,
          covers: bundle.display_asset_previews.as_json,
          taxonomy_id: bundle.taxonomy_id&.to_s,
          tags: bundle.tags.pluck(:name),
          display_product_reviews: bundle.display_product_reviews,
          is_adult: bundle.is_adult,
          discover_fee_per_thousand: bundle.discover_fee_per_thousand,
          section_ids: bundle.user.seller_profile_products_sections.filter_map { |section| section.external_id if section.shown_products.include?(bundle.id) },
          is_published: !bundle.draft && bundle.alive?,
          products: bundle.bundle_products.alive.in_order.includes(:variant, product: ProductPresenter::ASSOCIATIONS_FOR_CARD).map { self.class.bundle_product(product: _1.product, quantity: _1.quantity, selected_variant_id: _1.variant&.external_id) },
          collaborating_user: collaborator.present? ? UserPresenter.new(user: collaborator).author_byline_props : nil,
          public_files: bundle.alive_public_files.attached.map { PublicFilePresenter.new(public_file: _1).props },
          audio_previews_enabled: Feature.active?(:audio_previews, bundle.user),
        },
        id: bundle.external_id,
        unique_permalink: bundle.unique_permalink,
        is_bundle: bundle.is_bundle?,
      }
    end
end
