# frozen_string_literal: true

class CartPresenter
  attr_reader :logged_in_user, :ip, :cart

  def initialize(logged_in_user:, ip:, browser_guid:)
    @logged_in_user = logged_in_user
    @ip = ip
    @cart = Cart.fetch_by(user: logged_in_user, browser_guid:)
  end

  def cart_props
    return if cart.nil?

    cart_products = cart.cart_products.alive.order(created_at: :desc)

    {
      email: cart.email.presence,
      returnUrl: cart.return_url.presence || "",
      rejectPppDiscount: cart.reject_ppp_discount,
      discountCodes: cart.discount_codes.map do |discount_code|
        products = cart_products.each_with_object({}) { |cart_product, hash| hash[cart_product.product.unique_permalink] = { permalink: cart_product.product.unique_permalink, quantity: cart_product.quantity } }
        result = OfferCodeDiscountComputingService.new(discount_code["code"], products).process

        {
          code: discount_code["code"],
          fromUrl: discount_code["fromUrl"],
          products: result[:error_code].present? ? [] : result[:products_data].transform_values { _1[:discount] },
        }
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

          value[:accepted_offer][:discount] = accepted_offer.offer_code.discount if accepted_offer.offer_code.present?
        end

        value
      end
    }
  end

  private
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
      CheckoutPresenter.new(logged_in_user:, ip:).checkout_product(cart_product.product, cart_item, params)
    end
end
