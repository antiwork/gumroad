# frozen_string_literal: true

module Product::AsJson
  extend ActiveSupport::Concern

  included do
    alias super_as_json as_json
  end

  def as_json(options = {})
    return super(options) if options.delete(:original)
    return as_json_for_admin_info if options.delete(:admin_info)
    return as_json_for_api(options) if options[:api_scopes].present?
    return as_json_for_mobile_api if options.delete(:mobile)
    return as_json_variant_details_only if options.delete(:variant_details_only)

    json = super(only: %i[name description require_shipping preview_url]).merge!(
      "id" => unique_permalink,
      "external_id" => external_id,
      "price" => default_price_cents,
      "currency" => price_currency_type,
      "short_url" => long_url,
      "formatted_price" => price_formatted_verbose,
      "recommendable" => recommendable?,
      "rated_as_adult" => rated_as_adult?,
      "hide_sold_out_variants" => hide_sold_out_variants?,
    )
    json["custom_delivery_url"] = nil # Deprecated
    if preorder_link.present?
      json.merge!(
        "is_preorder" => true,
        "is_in_preorder_state" => is_in_preorder_state,
        "release_at" => preorder_link.release_at.to_s
      )
    end

    json
  end

  private
    def as_json_for_admin_info
      as_json(
        original: true,
        only: %i[
          purchase_type
        ],
        methods: %i[
          external_id
          long_url
          alive
          recommendable
          staff_picked
          is_in_preorder_state
          has_stampable_pdfs
          streamable
          is_physical
          is_licensed
          is_adult
          has_adult_keywords
        ],
        include: {
          user: { methods: :all_adult_products },
          tags: { methods: :humanized_name },
          active_integrations: { only: :type }
        }
      ).merge(
        taxonomy: taxonomy.as_json(methods: :ancestry_path),
        type: product_type_label,
        formatted_rental_price_cents: MoneyFormatter.format(rental_price_cents, price_currency_type.to_sym, no_cents_if_whole: true, symbol: true),
      )
    end

    def as_json_for_api(options)
      keep = %w[
        name description require_shipping preview_url
        custom_receipt customizable_price custom_permalink
        subscription_duration
      ]
      cached_default_price_cents = default_price_cents

      ppp_factors = purchasing_power_parity_enabled? ? options[:preloaded_ppp_factors] || PurchasingPowerParityService.new.get_all_countries_factors(user) : nil

      json = as_json(original: true, only: keep).merge!(
        "id" => external_id,
        "url" => nil, # Deprecated
        "price" => cached_default_price_cents,
        "currency" => price_currency_type,
        "short_url" => long_url,
        "thumbnail_url" => thumbnail&.alive&.url.presence,
        "tags" => tags.pluck(:name),
        "formatted_price" => price_formatted_verbose,
        "published" => alive?,
        "file_info" => multifile_aware_product_file_info,
        "max_purchase_count" => max_purchase_count,
        "deleted" => deleted_at.present?,
        "custom_fields" => custom_field_descriptors.as_json,
        "custom_summary" => custom_summary,
        "is_tiered_membership" => is_tiered_membership?,
        "recurrences" => is_tiered_membership? ? prices.alive.is_buy.map(&:recurrence).uniq : nil,
        "variants" => variant_categories_alive.map do |cat|
          {
            title: cat.title,
            options: cat.alive_variants.map do |variant|
              {
                name: variant.name,
                price_difference: variant.price_difference_cents,
                is_pay_what_you_want: variant.customizable_price?,
                recurrence_prices: is_tiered_membership? ? variant.recurrence_price_values : nil,
                url: nil, # Deprecated
              }
            end.map do
              ppp_factors.blank? ? _1 :
                _1.merge({
                           purchasing_power_parity_prices: _1[:price_difference].present? ? compute_ppp_prices(_1[:price_difference] + cached_default_price_cents, ppp_factors, currency) : nil,
                           recurrence_prices: _1[:recurrence_prices]&.transform_values do |v|
                             v.merge({ purchasing_power_parity_prices: compute_ppp_prices(v[:price_cents], ppp_factors, currency) })
                           end,
                         })
            end
          }
        end
      )

      if preorder_link.present?
        json.merge!(
          "is_preorder" => true,
          "is_in_preorder_state" => is_in_preorder_state,
          "release_at" => preorder_link.release_at.to_s
        )
      end

      if ppp_factors.present?
        json["purchasing_power_parity_prices"] = compute_ppp_prices(cached_default_price_cents, ppp_factors, currency)
      end

      if options[:api_scopes].include?("view_sales")
        json["custom_delivery_url"] = nil # Deprecated
        json["sales_count"] = successful_sales_count
        json["sales_usd_cents"] = total_usd_cents
      end

      json
    end

    def compute_ppp_prices(price_cents, factors, currency)
      factors.keys.index_with do |country_code|
        price_cents == 0 ? 0 : [factors[country_code] * price_cents, currency["min_price"]].max.round
      end
    end

    def as_json_for_mobile_api
      as_json(original: true, only: %w[name description unique_permalink]).merge!(
        created_at:,
        updated_at:,
        content_updated_at: content_updated_at || created_at,
        creator_name: user.name_or_username || "",
        creator_username: user.username || "",
        creator_profile_picture_url: user.avatar_url,
        creator_profile_url: user.profile_url,
        preview_url: preview_oembed_thumbnail_url || preview_url || "",
        thumbnail_url: thumbnail&.alive&.url.presence,
        preview_oembed_url: mobile_oembed_url,
        preview_height: preview_height_for_mobile,
        preview_width: preview_width_for_mobile,
        has_rich_content: true
      )
    end

    def as_json_variant_details_only
      variants = { categories: {}, skus: {}, skus_enabled: false }
      return variants if variant_categories_alive.empty? && !skus_enabled?

      variant_categories_alive.each do |category|
        category_hash = {
          title: category.title.present? ? category.title : "Version",
          options: {}
        }
        category.variants.alive.each do |variant|
          category_hash[:options][variant.external_id] = variant.as_json(for_views: true)
        end
        variants[:categories][category.external_id] = category_hash
      end

      if skus_enabled?
        skus.not_is_default_sku.alive.each do |sku|
          variants[:skus][sku.external_id] = sku.as_json(for_views: true)
        end
        variants[:skus_title] = sku_title
        variants[:skus_enabled] = true
      end

      variants
    end

    private
      def product_type_label
        return "Product" unless is_recurring_billing?
        return "Membership" if is_tiered_membership?

        "Subscription"
      end
end
