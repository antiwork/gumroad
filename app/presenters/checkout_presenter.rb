# frozen_string_literal: true

class CheckoutPresenter
  include Rails.application.routes.url_helpers
  include ActionView::Helpers::SanitizeHelper
  include CardParamsHelper
  include ProductsHelper
  include CurrencyHelper
  include PreorderHelper
  include CardParamsHelper

  attr_reader :logged_in_user, :ip

  def initialize(logged_in_user:, ip:)
    @logged_in_user = logged_in_user
    @ip = ip
  end

  def checkout_props(params:, browser_guid:)
    geo = GeoIp.lookup(@ip)
    detected_country = geo.try(:country_name)
    country = logged_in_user&.country || detected_country
    detected_state = geo.try(:region_name) if [Compliance::Countries::USA, Compliance::Countries::CAN].any? { |country| country.common_name == detected_country }
    credit_card = logged_in_user&.credit_card
    user = params[:username] && User.find_by_username(params[:username])
    {
      **checkout_common,
      country: Compliance::Countries.find_by_name(country)&.alpha2,
      state: logged_in_user&.state || detected_state,
      address: logged_in_user ? {
        street: logged_in_user.street_address,
        zip: logged_in_user.zip_code,
        city: logged_in_user.city,
      } : nil,
      saved_credit_card: CheckoutPresenter.saved_card(credit_card),
      gift: nil,
      clear_cart: false,
      **add_single_product_props(params:, user:),
      **checkout_wishlist_props(params:),
      **checkout_wishlist_gift_props(params:),
      cart: CartPresenter.new(logged_in_user:, ip:, browser_guid:).cart_props,
      max_allowed_cart_products: Cart::MAX_ALLOWED_CART_PRODUCTS,
      tip_options: TipOptionsService.get_tip_options,
      default_tip_option: TipOptionsService.get_default_tip_option,
    }
  end

  def checkout_product(product, cart_item, params, include_cross_sells: true)
    return unless product.present?
    upsell_variants = product.available_upsell_variants.alive.includes(:selected_variant, :offered_variant)
    bundle_products = product.bundle_products.in_order.includes(:product, :variant).alive.load
    accepted_offer = params[:accepted_offer_id] ? Upsell.available_to_customers.where(product:).find_by_external_id(params[:accepted_offer_id]) : nil
    option_id = accepted_offer&.variant&.external_id || cart_item[:option]&.fetch(:id)

    value = {
      product: {
        **product_common(product, recommended_by: params[:recommended_by]),
        id: product.external_id,
        duration_in_months: product.duration_in_months,
        url: product.long_url,
        thumbnail_url: product.thumbnail&.alive&.url,
        native_type: product.native_type,
        is_preorder: product.is_in_preorder_state,
        is_multiseat_license: product.is_multiseat_license?,
        is_quantity_enabled: product.quantity_enabled,
        quantity_remaining: product.remaining_for_sale_count,
        free_trial: product.free_trial_enabled ? {
          duration: {
            unit: product.free_trial_duration_unit,
            amount: product.free_trial_duration_amount
          }
        } : nil,
        cross_sells: [],
        has_offer_codes: product.has_offer_codes?,
        has_tipping_enabled: product.user.tipping_enabled && !product.is_tiered_membership && !product.is_recurring_billing?,
        require_shipping: product.require_shipping? || bundle_products.any? { _1.product.require_shipping? },
        analytics: product.analytics_data,
        rental: product.rental,
        recurrences: product.recurrences,
        can_gift: product.can_gift?,
        options: product.options.map do |option|
          upsell_variant = upsell_variants.find { |upsell_variant| upsell_variant.selected_variant.external_id == option[:id] }
          option.merge(
            {
              upsell_offered_variant_id: upsell_variant.present? &&
                (
                  product.upsell.seller == logged_in_user ||
                  purchases.none? { |purchase| purchase[:product] == product && purchase[:variant] == upsell_variant.offered_variant }
                ) &&
                upsell_variant.offered_variant.available? ?
                  upsell_variant.offered_variant.external_id :
                  nil
            }
          )
        end,
        ppp_details: product.ppp_details(@ip),
        upsell: product.available_upsell.present? ? {
          id: product.available_upsell.external_id,
          text: product.available_upsell.text,
          description: Rinku.auto_link(sanitize(product.available_upsell.description), :all, 'target="_blank" rel="noopener"'),
        } : nil,
        archived: product.archived?,
        bundle_products: bundle_products.map do |bundle_product|
          {
            product_id: bundle_product.product.external_id,
            name: bundle_product.product.name,
            native_type: bundle_product.product.native_type,
            thumbnail_url: bundle_product.product.thumbnail_alive&.url,
            quantity: bundle_product.quantity,
            variant: bundle_product.variant.present? ? { id: bundle_product.variant.external_id, name: bundle_product.variant.name } : nil,
            custom_fields: bundle_product.product.custom_field_descriptors,
          }
        end,
      },
      price: cart_item[:price],
      option_id:,
      rent: cart_item[:rental],
      recurrence: cart_item[:recurrence],
      quantity: cart_item[:quantity],
      call_start_time: cart_item[:call_start_time],
      pay_in_installments: cart_item[:pay_in_installments],
      affiliate_id: params[:affiliate_id],
      recommended_by: params[:recommended_by],
      recommender_model_name: params[:recommender_model_name],
      accepted_offer: accepted_offer ? { id: accepted_offer.external_id, variant_id: accepted_offer&.variant&.external_id, discount: accepted_offer.offer_code&.discount } : nil,
    }
    if include_cross_sells
      value[:product][:cross_sells] = product.available_cross_sells.filter_map do |cross_sell|
        next unless cross_sell.product.alive? &&
          (cross_sell.product.remaining_for_sale_count.nil? || cross_sell.product.remaining_for_sale_count > 0) &&
          (cross_sell.variant.blank? || cross_sell.variant.available?) &&
          (
            cross_sell.seller == logged_in_user ||
            purchases.none? { |purchase| purchase[:product] == cross_sell.product && purchase[:variant] == cross_sell.variant }
          )

        offered_product = cross_sell.product
        offered_product_cart_item = offered_product.cart_item(
          {
            option: cross_sell.variant&.external_id,
            recurrence: offered_product.default_price_recurrence&.recurrence
          }
        )
        {
          id: cross_sell.external_id,
          replace_selected_products: cross_sell.replace_selected_products,
          text: cross_sell.text,
          description: Rinku.auto_link(sanitize(cross_sell.description), :all, 'target="_blank" rel="noopener"'),
          offered_product: checkout_product(offered_product, offered_product_cart_item, {}, include_cross_sells: false),
          discount: cross_sell.offer_code&.discount,
          ratings: offered_product.display_product_reviews? ? {
            count: offered_product.reviews_count,
            average: offered_product.average_rating,
          } : nil,
        }
      end
    end
    value
  end

  def subscription_manager_props(subscription:)
    return nil unless subscription.present? && subscription.original_purchase.present?
    product = subscription.link
    tier_attrs = {
      recurrence: subscription.recurrence,
      variants: subscription.original_purchase.tiers,
      price_cents: subscription.current_plan_displayed_price_cents / subscription.original_purchase.quantity,
    }
    options = (variant_category = product.variant_categories_alive.first) ? variant_category.variants.in_order.alive.map do
      |variant| subscription.alive? && !subscription.overdue_for_charge? && product.recurrence_price_enabled?(subscription.recurrence) ? variant.to_option : variant.to_option(subscription_attrs: tier_attrs)
    end : []
    tier = subscription.original_purchase.variant_attributes.first
    if tier.present? && !options.any? { |option| option[:id] == tier.external_id }
      options << tier.to_option(subscription_attrs: tier_attrs)
    end
    offer_code = subscription.discount_applies_to_next_charge? ? subscription.original_offer_code : nil
    prices = product.prices.alive.is_buy.to_a
    if !prices.any? { |price| price.recurrence == subscription.recurrence }
      prices << product.prices.is_buy.where(recurrence: subscription.recurrence).order(deleted_at: :desc).take
    end

    {
      **checkout_common,
      product: {
        **product_common(product, recommended_by: nil),
        native_type: product.native_type,
        require_shipping: product.require_shipping?,
        recurrences: subscription.is_installment_plan ? [] : prices
                       .sort_by { |price| BasePrice::Recurrence.number_of_months_in_recurrence(price.recurrence) }
                       .map { |price| { id: price.external_id, recurrence: price.recurrence, price_cents: price.price_cents } },
        options:,
      },
      contact_info: {
        email: subscription.email,
        full_name: subscription.original_purchase.full_name || "",
        street: subscription.original_purchase.street_address || "",
        city: subscription.original_purchase.city || "",
        state: subscription.original_purchase.state || "",
        zip: subscription.original_purchase.zip_code || "",
        country: Compliance::Countries.find_by_name(subscription.original_purchase.country || subscription.original_purchase.ip_country)&.alpha2 || "",
      },
      used_card: CheckoutPresenter.saved_card(subscription.credit_card_to_charge),
      subscription: {
        id: subscription.external_id,
        option_id: (subscription.original_purchase.variant_attributes[0] || product.default_tier)&.external_id,
        recurrence: subscription.recurrence,
        price: subscription.current_subscription_price_cents,
        prorated_discount_price_cents: subscription.prorated_discount_price_cents,
        quantity: subscription.original_purchase.quantity,
        alive: subscription.alive?(include_pending_cancellation: false),
        pending_cancellation: subscription.pending_cancellation?,
        discount: offer_code&.discount,
        end_time_of_subscription: subscription.end_time_of_subscription.iso8601,
        successful_purchases_count: subscription.purchases.successful.count,
        is_in_free_trial: subscription.in_free_trial?,
        is_test: subscription.is_test_subscription,
        is_overdue_for_charge: subscription.overdue_for_charge?,
        is_gift: subscription.gift?,
        is_installment_plan: subscription.is_installment_plan,
      }
    }
  end

  def self.saved_card(card)
    card.present? && card.card_type != "paypal" ? { type: card.card_type, number: card.visual, expiration_date: card.expiry_visual, requires_mandate: card.requires_mandate? } : nil
  end

  private
    def add_single_product_props(params:, user:)
      product = params[:product] && (user ? Link.fetch_leniently(params[:product], user:) : Link.find_by_unique_permalink(params[:product]))
      cart_item = product.cart_item(params) if product
      {
        add_products: [checkout_product(product, cart_item, params)].compact
      }
    end

    def checkout_wishlist_props(params:)
      return {} if params[:wishlist].blank?
      wishlist = Wishlist.alive.includes(wishlist_products: [:product, :variant]).find_by_external_id(params[:wishlist])
      return {} if wishlist.blank?

      {
        add_products: wishlist.alive_wishlist_products.available_to_buy.map do |wishlist_product|
          checkout_wishlist_product(wishlist_product, params.reverse_merge(affiliate_id: wishlist_product.wishlist.user.global_affiliate.external_id_numeric.to_s))
        end
      }
    end

    def checkout_wishlist_gift_props(params:)
      return {} if params[:gift_wishlist_product].blank?
      wishlist_product = WishlistProduct.alive.find_by_external_id(params[:gift_wishlist_product])
      return {} if wishlist_product.blank? || wishlist_product.wishlist.user == logged_in_user

      {
        clear_cart: true,
        add_products: [checkout_wishlist_product(wishlist_product, params)],
        gift: { type: "anonymous", id: wishlist_product.wishlist.user.external_id, name: wishlist_product.wishlist.user.name_or_username, note: "" }
      }
    end

    def checkout_wishlist_product(wishlist_product, params)
      cart_item = wishlist_product.product.cart_item(
        option: wishlist_product.variant&.external_id,
        rent: wishlist_product.rent,
        recurrence: wishlist_product.recurrence,
        quantity: wishlist_product.quantity,
      )
      checkout_product(
        wishlist_product.product,
        cart_item,
        params.reverse_merge(recommended_by: RecommendationType::WISHLIST_RECOMMENDATION),
      )
    end

    def checkout_common
      {
        discover_url: discover_url(protocol: PROTOCOL, host: DISCOVER_DOMAIN),
        countries: Compliance::Countries.for_select.to_h,
        us_states: STATES,
        ca_provinces: Compliance::Countries.subdivisions_for_select(Compliance::Countries::CAN.alpha2).map(&:first),
        recaptcha_key: GlobalConfig.get("RECAPTCHA_MONEY_SITE_KEY"),
        paypal_client_id: PAYPAL_PARTNER_CLIENT_ID,
      }
    end

    def product_common(product, recommended_by:)
      {
        permalink: product.unique_permalink,
        name: product.name,
        creator: product.user.username ? {
          name: product.user.name || product.user.username,
          profile_url: product.user.profile_url(recommended_by:),
          avatar_url: product.user.avatar_url,
          id: product.user.external_id,
        } : nil,
        currency_code: product.price_currency_type.downcase,
        price_cents: product.price_cents,
        supports_paypal: supports_paypal(product),
        custom_fields: product.custom_field_descriptors,
        exchange_rate: get_rate(product.price_currency_type).to_f / (is_currency_type_single_unit?(product.price_currency_type) ? 100 : 1),
        is_tiered_membership: product.is_tiered_membership,
        is_legacy_subscription: product.is_legacy_subscription?,
        pwyw: product.customizable_price ? { suggested_price_cents: product.suggested_price_cents } : nil,
        installment_plan: product.installment_plan ? {
          number_of_installments: product.installment_plan.number_of_installments,
          recurrence: product.installment_plan.recurrence,
        } : nil,
        is_multiseat_license: product.is_tiered_membership && product.is_multiseat_license,
        shippable_country_codes: product.is_physical ? product.shipping_destinations.alive.flat_map { |shipping_destination| shipping_destination.country_or_countries.keys } : [],
      }
    end

    def supports_paypal(product)
      return if Feature.active?(:disable_paypal_sales)
      return if Feature.active?(:disable_nsfw_paypal_connect_sales) && product.rated_as_adult?

      if Feature.active?(:disable_paypal_connect_sales)
        return if product.is_recurring_billing? || !product.user.pay_with_paypal_enabled?
        "braintree"
      elsif product.user.native_paypal_payment_enabled?
        "native"
      elsif product.user.pay_with_paypal_enabled?
        "braintree"
      end
    end

    def purchases
      @_purchases ||= logged_in_user&.purchases&.map { |purchase| { product: purchase.link, variant: purchase.variant_attributes.first } } || []
    end
end
