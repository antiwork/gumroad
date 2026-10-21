# frozen_string_literal: true

class CartPresenter
  attr_reader :logged_in_user, :ip, :cart, :checkout_presenter

  def initialize(logged_in_user:, ip:, browser_guid:)
    @logged_in_user = logged_in_user
    @ip = ip
    @cart = Cart.fetch_by(user: logged_in_user, browser_guid:)
    @checkout_presenter = CheckoutPresenter.new(logged_in_user:, ip:)
  end

  def cart_props
    return if cart.nil?

    cart_products = cart.visible_cart_products
      .preload(
        :option,
        :affiliate,
        { accepted_offer: :offer_code },
        { product: [
          :user,
          :thumbnail,
          :installment_plan,
          :variant_categories_alive,
          :alive_variants,
          :default_offer_code,
          { available_upsell: :seller },
        ] }
      ).load

    discount_products = cart_products.to_h do |cart_product|
      [cart_product.id, {
        permalink: cart_product.product.unique_permalink,
        quantity: cart_product.quantity,
        variant_external_id: cart_product.option&.external_id || "",
      }]
    end

    {
      email: cart.email.presence,
      returnUrl: cart.return_url.presence || "",
      rejectPppDiscount: cart.reject_ppp_discount,
      discountCodes: discount_codes_with_defaults(cart_products).filter_map do |discount_code|
        result = OfferCodeDiscountComputingService.new(OfferCode.normalize_code(discount_code["code"]), discount_products, buyer: logged_in_user).process
        products = result[:error_code].present? ? {} : result[:products_data].transform_values { _1[:discount] }
        # A default that covers no line yet is left out; the save after the edit that qualifies it asks again.
        next if discount_code["automatic"] && products.empty?

        { code: discount_code["code"], fromUrl: discount_code["fromUrl"], products:, **(discount_code["automatic"] ? { automatic: true } : {}) }
      end,
      items: cart_products.map do |cart_product|
        value = {
          **checkout_product(cart_product),
          url_parameters: cart_product.url_parameters,
          referrer: cart_product.referrer,
        }

        accepted_offer = cart_product.accepted_offer
        if cart_product.accepted_offer.present? && cart_product.accepted_offer_details.present?
          value[:accepted_offer] = {
            id: accepted_offer.external_id,
            **cart_product.accepted_offer_details.symbolize_keys,
          }

          value[:accepted_offer][:discount] = accepted_offer.offer_code.discount_for_display(buyer: logged_in_user, product: accepted_offer.product) if accepted_offer.offer_code.present?
        end

        value
      end
    }
  end

  private
    # Every cart save answers with these, so each line is weighed against its product's defaults on the
    # cart as it stands; the quote above drops the ones this buyer cannot redeem. The checkout keeps the
    # later code on a tie, so the defaults go last, and a name any product uses for an existing-customer
    # default goes after every sale: sellers can share a code name, and the cart quotes it once.
    def discount_codes_with_defaults(cart_products)
      offer_codes = cart_products.flat_map { BestOfferCodeService.new(product: _1.product, buyer: logged_in_user).default_offer_codes }
      existing_customer_names = offer_codes.filter_map { OfferCode.normalize_code(_1.code) if _1.existing_customers_only? }
      defaults = offer_codes.filter_map { _1.code.presence }.uniq { OfferCode.normalize_code(_1) }
        .partition { !existing_customer_names.include?(OfferCode.normalize_code(_1)) }.flatten
      # Only a current default is automatic: a flag a saved row carries would pin a code the buyer can't remove.
      stored = cart.discount_codes.map { _1.except("automatic") }.index_by { OfferCode.normalize_code(_1["code"]) }

      # A code the buyer typed stays theirs to remove, even when it is also a default.
      stored.except(*defaults.map { OfferCode.normalize_code(_1) }).values + defaults.map do |code|
        typed = stored[OfferCode.normalize_code(code)]
        typed && !typed["fromUrl"] ? typed : (typed || { "code" => code, "fromUrl" => true }).merge("automatic" => true)
      end
    end

    def checkout_product(cart_product)
      params = {
        recommended_by: cart_product.recommended_by,
        affiliate_id: cart_product.affiliate&.external_id_numeric&.to_s,
        recommender_model_name: cart_product.recommender_model_name,
      }
      cart_item = cart_product.product.cart_item(
        price: cart_product.price,
        option: cart_product.option&.external_id,
        rent: cart_product.rent,
        recurrence: cart_product.recurrence,
        quantity: cart_product.quantity,
        call_start_time: cart_product.call_start_time,
        pay_in_installments: cart_product.pay_in_installments,
      )
      checkout_presenter.checkout_product(cart_product.product, cart_item, params)
    end
end
