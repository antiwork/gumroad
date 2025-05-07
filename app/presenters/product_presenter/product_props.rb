# frozen_string_literal: true

class ProductPresenter::ProductProps
  include Rails.application.routes.url_helpers
  include ProductsHelper

  SALES_COUNT_CACHE_KEY_REFIX = "product-presenter:sales-count-cache"
  SALES_COUNT_CACHE_METRICS_KEY = "#{SALES_COUNT_CACHE_KEY_REFIX}-metrics"

  def initialize(product:)
    @product = product
    @seller = product.user
  end

  def props(seller_custom_domain_url:, request:, pundit_user:, recommended_by: nil, discount_code: nil, quantity: 1, layout: nil)
    {
      product: {
        id: product.external_id,
        permalink: product.unique_permalink,
        name: product.name,
        seller: UserPresenter.new(user: seller).author_byline_props(custom_domain_url: seller_custom_domain_url, recommended_by:),
        collaborating_user: collaborator.present? ? UserPresenter.new(user: collaborator).author_byline_props : nil,
        covers: product.display_asset_previews.as_json,
        main_cover_id: product.main_preview&.guid,
        thumbnail_url: product.thumbnail&.alive&.url,
        quantity_remaining: product.remaining_for_sale_count,
        long_url: product.long_url,
        is_sales_limited: product.max_purchase_count?,
        ratings: product.display_product_reviews? ? product.rating_stats : nil,
        custom_button_text_option: product.custom_button_text_option,
        is_compliance_blocked: product.compliance_blocked(request.remote_ip),
        is_published: !product.draft && product.alive?,
        is_stream_only: product.has_stream_only_files?,
        streamable: product.streamable?,
        sales_count: cached_sales_count,
        summary: product.custom_summary.presence,
        attributes: attributes_props,
        description_html: product.html_safe_description,
        currency_code: product.price_currency_type.downcase,
        price_cents: product.price_cents,
        rental_price_cents: product.rental_price_cents,
        pwyw: product.customizable_price ? { suggested_price_cents: product.suggested_price_cents } : nil,
        **ProductPresenter::InstallmentPlanProps.new(product:).props,
        is_legacy_subscription: product.is_legacy_subscription?,
        is_tiered_membership: product.is_tiered_membership,
        is_physical: product.is_physical,
        custom_view_content_button_text: product.custom_view_content_button_text.presence,
        is_multiseat_license: product.is_tiered_membership && product.is_multiseat_license,
        native_type: product.native_type,
        preorder: product.is_in_preorder_state ? { release_date: product.preorder_link.release_at } : nil,
        duration_in_months: product.duration_in_months,
        rental: product.rental,
        is_quantity_enabled: product.quantity_enabled,
        free_trial: product.free_trial_enabled ? {
          duration: {
            unit: product.free_trial_duration_unit,
            amount: product.free_trial_duration_amount
          }
        } : nil,
        recurrences: product.recurrences,
        options: product.options,
        analytics: product.analytics_data,
        has_third_party_analytics: product.has_third_party_analytics?("product"),
        ppp_details: product.ppp_details(request.remote_ip),
        can_edit: pundit_user&.user ? Pundit.policy!(pundit_user, product).edit? : false,
        refund_policy: refund_policy_props,
        bundle_products: product.bundle_products.in_order.includes(:product, :variant).alive.map { bundle_product_props(_1, request:, recommended_by:, layout:) },
        public_files: product.alive_public_files.attached.map { PublicFilePresenter.new(public_file: _1).props },
        audio_previews_enabled: Feature.active?(:audio_previews, product.user),
      },
      discount_code: discount_code_props(discount_code, quantity),
      purchase: purchase_props(product.purchase_info_for_product_page(pundit_user&.user, request.cookie_jar[:_gumroad_guid])),
      wishlists: pundit_user&.seller.present? ? (
        pundit_user.seller.wishlists.alive.includes(:alive_wishlist_products).map { |wishlist| WishlistPresenter.new(wishlist:).listing_props(product:) }
      ) : [],
    }
  end

  private
    attr_reader :product, :seller

    def discount_code_props(discount_code, quantity)
      return if discount_code.blank?

      offer_code_response = OfferCodeDiscountComputingService.new(
        discount_code,
        {
          product.unique_permalink => {
            permalink: product.unique_permalink,
            quantity: [quantity, product.find_offer_code(code: discount_code)&.minimum_quantity || 0].max
          }
        }
      ).process

      if offer_code_response[:error_code].present?
        { valid: false, error_code: offer_code_response[:error_code] }
      else
        { valid: true, code: discount_code, **offer_code_response[:products_data][product.unique_permalink] }
      end
    end

    def purchase_props(purchase_info)
      return if purchase_info.blank?

      {
        id: purchase_info[:id],
        email_digest: purchase_info[:email_digest],
        created_at: purchase_info[:created_at],
        review: purchase_info[:review],
        should_show_receipt: purchase_info[:should_show_receipt],
        is_gift_receiver_purchase: purchase_info[:is_gift_receiver_purchase],
        show_view_content_button_on_product_page: purchase_info[:show_view_content_button_on_product_page],
        total_price_including_tax_and_shipping: purchase_info[:total_price_including_tax_and_shipping],
        content_url: purchase_info[:content_url],
        subscription_has_lapsed: purchase_info[:subscription_has_lapsed],
        membership: purchase_info[:membership],
      }
    end

    def attributes_props
      product.custom_attributes.filter_map { |attr|
        { name: attr["name"], value: attr["value"] } if attr["name"].present? || attr["value"].present?
      } + product.file_info_for_product_page.map { |k, v| { name: k.to_s, value: v } }
    end

    def collaborator
      @_collaborator ||= product.collaborator_for_display
    end

    def cached_sales_count
      return unless product.should_show_sales_count?

      cache_key_digest = Digest::SHA256.hexdigest("#{product.cache_key}-#{product.price_cents}-#{product.sales.order(id: :desc).pick(:id)}")
      cache_key = "#{SALES_COUNT_CACHE_KEY_REFIX}_#{cache_key_digest}"
      Rails.cache.fetch(cache_key, expires_in: 1.minute) { product.successful_sales_count }
    end

    def bundle_product_props(bundle_product, request:, recommended_by: nil, layout: nil)
      product = bundle_product.product
      {
        id: product.external_id,
        name: product.name,
        ratings: product.display_product_reviews? ? {
          count: product.reviews_count,
          average: product.average_rating,
        } : nil,
        price: bundle_product.standalone_price_cents,
        currency_code: product.price_currency_type.downcase,
        thumbnail_url: product.thumbnail_alive&.url,
        native_type: product.native_type,
        url: url_for_product_page(product, request:, recommended_by:, layout:),
        quantity: bundle_product.quantity,
        variant: bundle_product.variant&.name,
      }
    end

    def refund_policy_props
      if seller.account_level_refund_policy_enabled?
        {
          title: seller.refund_policy.title,
          fine_print: seller.refund_policy.fine_print.present? ? ActionController::Base.helpers.simple_format(seller.refund_policy.fine_print) : nil,
          updated_at: seller.refund_policy.updated_at.to_date,
        }
      elsif product.product_refund_policy_enabled?
        {
          title: product.product_refund_policy.title,
          fine_print: product.product_refund_policy.fine_print.present? ? ActionController::Base.helpers.simple_format(product.product_refund_policy.fine_print) : nil,
          updated_at: product.product_refund_policy.updated_at.to_date,
        }
      else
        nil
      end
    end
end
