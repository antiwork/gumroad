# frozen_string_literal: true

class Products::Edit::BasePresenter
  include Rails.application.routes.url_helpers
  include ProductsHelper
  include CurrencyHelper
  include PreorderHelper

  attr_reader :product, :pundit_user

  def initialize(product:, pundit_user:)
    @product = product
    @pundit_user = pundit_user
  end

  # Top-level props required by the shared layout (no product; each tab adds its own product).
  def layout_props
    {
      id: product.external_id,
      unique_permalink: product.unique_permalink,
      seller: UserPresenter.new(user: product.user).author_byline_props,
      existing_files: legacy_presenter.existing_files,
      ai_generated: false,
      currency_type: product.price_currency_type,
      taxonomies: Discover::TaxonomyPresenter.new.taxonomies_for_nav,
      earliest_membership_price_change_date: ::BaseVariant::MINIMUM_DAYS_TIL_EXISTING_MEMBERSHIP_PRICE_CHANGE.days.from_now.in_time_zone(product.user.timezone).iso8601,
      available_countries: ::ShippingDestination::Destinations.shipping_countries.map { { code: _1[0], name: _1[1] } },
      google_client_id: ::GlobalConfig.get("GOOGLE_CLIENT_ID"),
      google_calendar_enabled: Feature.active?(:google_calendar_link, product.user),
      cancellation_discounts_enabled: Feature.active?(:cancellation_discounts, product.user),
      thumbnail: product.thumbnail&.alive&.as_json,
      refund_policies: product.user.product_refund_policies.for_visible_and_not_archived_products.where.not(product_id: product.id).order(updated_at: :desc).select("refund_policies.*", "links.name").as_json,
      is_tiered_membership: product.is_tiered_membership,
      is_listed_on_discover: product.recommendable?,
      is_physical: product.is_physical,
      profile_sections: product.user.seller_profile_products_sections.map { { id: _1.external_id, header: _1.header || "", product_names: _1.product_names, default: _1.add_new_products } },
      sales_count_for_inventory: product.max_purchase_count? ? product.sales_count_for_inventory : 0,
      successful_sales_count: product.successful_sales_count,
      ratings: product.rating_stats,
      aws_key: AWS_ACCESS_KEY,
      s3_url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}",
      seller_refund_policy_enabled: product.user.account_level_refund_policy_enabled?,
      seller_refund_policy: {
        title: product.user.refund_policy.title,
        fine_print: product.user.refund_policy.fine_print,
      },
      custom_domain_verification_status:,
    }
  end

  # Minimal product keys required by the layout (name, is_published, files, native_type).
  def product_minimal_props
    {
      name: product.name,
      is_published: !product.draft && product.alive?,
      files: files_data,
      native_type: product.native_type,
    }
  end

  protected

    def legacy_presenter
      @legacy_presenter ||= ::ProductPresenter.new(product:, pundit_user:)
    end

    def custom_domain_verification_status
      legacy_presenter.send(:custom_domain_verification_status)
    end

    def collaborating_user_props
      collaborator = product.collaborator_for_display
      collaborator.present? ? UserPresenter.new(user: collaborator).author_byline_props : nil
    end

    def files_data
      product.product_files.alive.in_order.includes(:alive_subtitle_files).map(&:as_json)
    end

    def variants_data
      product.alive_variants.in_order.map do |variant|
        props = {
          id: variant.external_id,
          name: variant.name || "",
          description: variant.description || "",
          max_purchase_count: variant.max_purchase_count,
          integrations: ::Integration::ALL_NAMES.index_with { |name| variant.find_integration_by_name(name).present? },
          rich_content: variant.rich_content_json,
          sales_count_for_inventory: variant.max_purchase_count? ? variant.sales_count_for_inventory : 0,
          active_subscribers_count: variant.active_subscribers_count,
        }
        props[:duration_in_minutes] = variant.duration_in_minutes if product.native_type == ::Link::NATIVE_TYPE_CALL
        if product.native_type == ::Link::NATIVE_TYPE_MEMBERSHIP
          props.merge!(
            customizable_price: !!variant.customizable_price,
            recurrence_price_values: variant.recurrence_price_values(for_edit: true),
            apply_price_changes_to_existing_memberships: variant.apply_price_changes_to_existing_memberships?,
            subscription_price_change_effective_date: variant.subscription_price_change_effective_date,
            subscription_price_change_message: variant.subscription_price_change_message,
          )
        else
          props[:price_difference_cents] = variant.price_difference_cents
        end
        props
      end
    end

    def availabilities_data
      return [] unless product.native_type == Link::NATIVE_TYPE_CALL

      product.call_availabilities.map do |availability|
        {
          id: availability.external_id,
          start_time: availability.start_time.iso8601,
          end_time: availability.end_time.iso8601,
        }
      end
    end

    def public_files_data
      product.alive_public_files.attached.map { PublicFilePresenter.new(public_file: _1).props }
    end
end
