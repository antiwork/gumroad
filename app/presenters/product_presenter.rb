# frozen_string_literal: true

class ProductPresenter
  include Rails.application.routes.url_helpers
  include ProductsHelper
  include CurrencyHelper
  include PreorderHelper

  extend PreorderHelper

  attr_reader :product, :editing_page_id, :pundit_user, :request

  delegate :user, :skus,
           :skus_enabled, :is_licensed, :is_multiseat_license, :quantity_enabled, :description,
           :is_recurring_billing, :should_include_last_post, :should_show_all_posts, :should_show_sales_count,
           :block_access_after_membership_cancellation, :duration_in_months, to: :product, allow_nil: true

  def initialize(product:, editing_page_id: nil, request: nil, pundit_user: nil)
    @product = product
    @editing_page_id = editing_page_id
    @request = request
    @pundit_user = pundit_user
  end

  def self.new_page_props(current_seller:)
    native_product_types = Link::NATIVE_TYPES - Link::LEGACY_TYPES - Link::SERVICE_TYPES
    native_product_types -= [Link::NATIVE_TYPE_PHYSICAL] unless current_seller.can_create_physical_products?
    service_product_types = Link::SERVICE_TYPES
    service_product_types -= [Link::NATIVE_TYPE_COMMISSION] unless Feature.active?(:commissions, current_seller)
    release_at_date = displayable_release_at_date(1.month.from_now, current_seller.timezone)

    {
      current_seller_currency_code: current_seller.currency_type,
      native_product_types:,
      service_product_types:,
      release_at_date:,
      show_orientation_text: current_seller.products.visible.none?,
      eligible_for_service_products: current_seller.eligible_for_service_products?,
      ai_generation_enabled: current_seller.eligible_for_ai_product_generation?,
      ai_promo_dismissed: current_seller.dismissed_create_products_with_ai_promo_alert?,
    }
  end

  ASSOCIATIONS_FOR_CARD = ProductPresenter::Card::ASSOCIATIONS
  def self.card_for_web(product:, request: nil, recommended_by: nil, recommender_model_name: nil, target: nil, show_seller: true, affiliate_id: nil, query: nil, compute_description: true)
    ProductPresenter::Card.new(product:).for_web(request:, recommended_by:, recommender_model_name:, target:, show_seller:, affiliate_id:, query:, compute_description:)
  end

  def self.card_for_email(product:)
    ProductPresenter::Card.new(product:).for_email
  end

  def product_props(**kwargs)
    ProductPresenter::ProductProps.new(product:).props(request:, pundit_user:, **kwargs)
  end

  def product_page_props(seller_custom_domain_url:, **kwargs)
    sections_props = ProfileSectionsPresenter.new(seller: user, query: product.seller_profile_sections).props(request:, pundit_user:, seller_custom_domain_url:)
    {
      **product_props(seller_custom_domain_url:, **kwargs),
      **sections_props,
      sections: product.sections.filter_map { |id| sections_props[:sections].find { |section| section[:id] === ObfuscateIds.encrypt(id) } },
      main_section_index: product.main_section_index || 0,
    }
  end

  def covers
    {
      covers: product.display_asset_previews.as_json,
      main_cover_id: product.main_preview&.guid
    }
  end

  def existing_files
    user.alive_product_files_preferred_for_product(product)
        .limit($redis.get(RedisKey.product_presenter_existing_product_files_limit))
        .order(id: :desc)
        .includes(:alive_subtitle_files).map { _1.as_json(existing_product_file: true) }
  end

  def edit_props
    refund_policy = product.find_or_initialize_product_refund_policy
    profile_sections = product.user.seller_profile_products_sections
    collaborator = product.collaborator_for_display
    cancellation_discount = product.cancellation_discount_offer_code
    {
      product: {
        name: product.name,
        custom_permalink: product.custom_permalink,
        description: product.description || "",
        price_cents: product.price_cents,
        customizable_price: !!product.customizable_price,
        suggested_price_cents: product.suggested_price_cents,
        **ProductPresenter::InstallmentPlanProps.new(product:).props,
        custom_button_text_option: product.custom_button_text_option.presence,
        custom_summary: product.custom_summary,
        custom_attributes: product.custom_attributes,
        file_attributes: product.file_info_for_product_page.map { { name: _1.to_s, value: _2 } },
        max_purchase_count: product.max_purchase_count,
        quantity_enabled: product.quantity_enabled,
        can_enable_quantity: product.can_enable_quantity?,
        should_show_sales_count: product.should_show_sales_count,
        hide_sold_out_variants: product.hide_sold_out_variants?,
        is_epublication: product.is_epublication?,
        product_refund_policy_enabled: product.product_refund_policy_enabled?,
        refund_policy: {
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
        },
        covers: product.display_asset_previews.as_json,
        is_published: !product.draft && product.alive?,
        require_shipping: product.require_shipping?,
        integrations: Integration::ALL_NAMES.index_with { |name| @product.find_integration_by_name(name).as_json },
        variants: product.alive_variants.in_order.map do |variant|
          props = {
            id: variant.external_id,
            name: variant.name || "",
            description: variant.description || "",
            max_purchase_count: variant.max_purchase_count,
            integrations: Integration::ALL_NAMES.index_with { |name| variant.find_integration_by_name(name).present? },
            rich_content: variant.rich_content_json,
            sales_count_for_inventory: variant.max_purchase_count? ? variant.sales_count_for_inventory : 0,
            active_subscribers_count: variant.active_subscribers_count,
          }
          props[:duration_in_minutes] = variant.duration_in_minutes if product.native_type == Link::NATIVE_TYPE_CALL
          if product.native_type == Link::NATIVE_TYPE_MEMBERSHIP
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
        end,
        availabilities: product.native_type == Link::NATIVE_TYPE_CALL ?
          product.call_availabilities.map do |availability|
            {
              id: availability.external_id,
              start_time: availability.start_time.iso8601,
              end_time: availability.end_time.iso8601,
            }
          end : [],
        shipping_destinations: product.shipping_destinations.alive.map do |shipping_destination|
          {
            country_code: shipping_destination.country_code,
            one_item_rate_cents: shipping_destination.one_item_rate_cents,
            multiple_items_rate_cents: shipping_destination.multiple_items_rate_cents,
          }
        end,
        section_ids: profile_sections.filter_map { |section| section.external_id if section.shown_products.include?(product.id) },
        taxonomy_id: product.taxonomy_id&.to_s,
        tags: product.tags.pluck(:name),
        display_product_reviews: product.display_product_reviews,
        is_adult: product.is_adult,
        discover_fee_per_thousand: product.discover_fee_per_thousand,
        custom_domain: product.custom_domain&.domain || "",
        free_trial_enabled: product.free_trial_enabled,
        free_trial_duration_amount: product.free_trial_duration_amount,
        free_trial_duration_unit: product.free_trial_duration_unit,
        should_include_last_post: product.should_include_last_post,
        should_show_all_posts: product.should_show_all_posts,
        block_access_after_membership_cancellation: product.block_access_after_membership_cancellation,
        duration_in_months: product.duration_in_months,
        subscription_duration: product.subscription_duration,
        collaborating_user: collaborator.present? ? UserPresenter.new(user: collaborator).author_byline_props : nil,
        rich_content: product.rich_content_json,
        files: files_data(product),
        has_same_rich_content_for_all_variants: @product.has_same_rich_content_for_all_variants?,
        is_multiseat_license:,
        call_limitation_info: product.native_type == Link::NATIVE_TYPE_CALL && product.call_limitation_info.present? ?
          {
            minimum_notice_in_minutes: product.call_limitation_info.minimum_notice_in_minutes,
            maximum_calls_per_day: product.call_limitation_info.maximum_calls_per_day,
          } : nil,
        native_type: product.native_type,
        cancellation_discount: cancellation_discount.present? ? {
          discount:
            cancellation_discount.is_cents? ?
            { type: "fixed", cents: cancellation_discount.amount_cents } :
            { type: "percent", percents: cancellation_discount.amount_percentage },
          duration_in_billing_cycles: cancellation_discount.duration_in_billing_cycles,
        } : nil,
        public_files: product.alive_public_files.attached.map { PublicFilePresenter.new(public_file: _1).props },
        audio_previews_enabled: Feature.active?(:audio_previews, product.user),
        community_chat_enabled: Feature.active?(:communities, product.user) ? product.community_chat_enabled? : nil,
      },
      id: product.external_id,
      unique_permalink: product.unique_permalink,
      thumbnail: product.thumbnail&.alive&.as_json,
      refund_policies: product.user
        .product_refund_policies
        .for_visible_and_not_archived_products
        .where.not(product_id: product.id)
        .order(updated_at: :desc)
        .select("refund_policies.*", "links.name")
        .as_json,
      currency_type: product.price_currency_type,
      is_tiered_membership: product.is_tiered_membership,
      is_listed_on_discover: product.recommendable?,
      is_physical: product.is_physical,
      profile_sections: profile_sections.map do |section|
        {
          id: section.external_id,
          header: section.header || "",
          product_names: section.product_names,
          default: section.add_new_products,
        }
      end,
      taxonomies: Discover::TaxonomyPresenter.new.taxonomies_for_nav,
      earliest_membership_price_change_date: BaseVariant::MINIMUM_DAYS_TIL_EXISTING_MEMBERSHIP_PRICE_CHANGE.days.from_now.in_time_zone(product.user.timezone).iso8601,
      custom_domain_verification_status:,
      sales_count_for_inventory: product.max_purchase_count? ? product.sales_count_for_inventory : 0,
      successful_sales_count: product.successful_sales_count,
      ratings: product.rating_stats,
      seller: UserPresenter.new(user:).author_byline_props,
      existing_files:,
      s3_url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}",
      aws_key: AWS_ACCESS_KEY,
      available_countries: ShippingDestination::Destinations.shipping_countries.map { { code: _1[0], name: _1[1] } },
      google_client_id: GlobalConfig.get("GOOGLE_CLIENT_ID"),
      google_calendar_enabled: Feature.active?(:google_calendar_link, product.user),
      seller_refund_policy_enabled: product.user.account_level_refund_policy_enabled?,
      seller_refund_policy: {
        title: product.user.refund_policy.title,
        fine_print: product.user.refund_policy.fine_print,
      },
      cancellation_discounts_enabled: Feature.active?(:cancellation_discounts, product.user),
    }
  end

  def admin_info
    {
      custom_summary: product.custom_summary.presence,
      file_info_attributes: product.file_info_for_product_page.map do |k, v|
        { name: k.to_s, value: v }
      end,
      custom_attributes: product.custom_attributes.filter_map do |attr|
        { name: attr["name"], value: attr["value"] } if attr["name"].present? || attr["value"].present?
      end,
      preorder: product.is_in_preorder_state ? { release_date_fmt: displayable_release_at_date_and_time(product.preorder_link.release_at, product.user.timezone) } : nil,
      has_stream_only_files: product.has_stream_only_files?,
      should_show_sales_count: product.should_show_sales_count,
      sales_count: product.should_show_sales_count ? product.successful_sales_count : 0,
      is_recurring_billing: product.is_recurring_billing,
      price_cents: product.price_cents,
    }
  end

  private
    def default_sku
      skus_enabled && skus.alive.not_is_default_sku.empty? ? skus.is_default_sku.first : nil
    end

    def collaborating_user
      return @_collaborating_user if defined?(@_collaborating_user)

      collaborator = product.collaborator_for_display
      @_collaborating_user = collaborator.present? ? UserPresenter.new(user: collaborator).author_byline_props : nil
    end

    def rich_content_pages
      variants = @product.alive_variants.includes(:alive_rich_contents, variant_category: { link: :user })

      if refer_to_product_level_rich_content?(has_variants: variants.size > 0)
        product.rich_content_json
      else
        variants.flat_map(&:rich_content_json)
      end
    end

    def refer_to_product_level_rich_content?(has_variants:)
      product.is_physical? || !has_variants || product.has_same_rich_content_for_all_variants?
    end

    def custom_domain_verification_status
      custom_domain = @product.custom_domain
      return if custom_domain.blank?

      domain = custom_domain.domain
      if custom_domain.verified?
        {
          success: true,
          message: "#{domain} domain is correctly configured!",
        }
      else
        {
          success: false,
          message: "Domain verification failed. Please make sure you have correctly configured the DNS record for #{domain}.",
        }
      end
    end
end
