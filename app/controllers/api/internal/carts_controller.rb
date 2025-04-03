# frozen_string_literal: true

class Api::Internal::CartsController < Api::Internal::BaseController
  def update
    if permitted_cart_params[:items].length > Cart::MAX_ALLOWED_CART_PRODUCTS
      return render json: { error: "You cannot add more than #{Cart::MAX_ALLOWED_CART_PRODUCTS} products to the cart." }, status: :unprocessable_entity
    end

    ActiveRecord::Base.transaction do
      browser_guid = cookies[:_gumroad_guid]
      cart = Cart.fetch_by(user: logged_in_user, browser_guid:) || Cart.new(user: logged_in_user, browser_guid:)
      cart.ip_address = request.remote_ip
      cart.browser_guid = browser_guid
      cart.email = permitted_cart_params[:email].presence || logged_in_user&.email
      cart.return_url = permitted_cart_params[:returnUrl]
      cart.reject_ppp_discount = permitted_cart_params[:rejectPppDiscount] || false
      cart.discount_codes = permitted_cart_params[:discountCodes].map { { code: _1[:code], fromUrl: _1[:fromUrl] } }
      cart.save!

      updated_cart_products = permitted_cart_params[:items].map do |item|
        product = Link.find_by_external_id!(item[:product][:id])
        option = item[:option_id].present? ? BaseVariant.find_by_external_id(item[:option_id]) : nil

        cart_product = cart.cart_products.alive.find_or_initialize_by(product:, option:)
        cart_product.affiliate = item[:affiliate_id].to_i.zero? ? nil : Affiliate.find_by_external_id_numeric(item[:affiliate_id].to_i)
        accepted_offer = item[:accepted_offer]
        if accepted_offer.present? && accepted_offer[:id].present?
          cart_product.accepted_offer = Upsell.find_by_external_id(accepted_offer[:id])
          cart_product.accepted_offer_details = {
            original_product_id: accepted_offer[:original_product_id],
            original_variant_id: accepted_offer[:original_variant_id],
          }
        end
        cart_product.price = item[:price]
        cart_product.quantity = item[:quantity]
        cart_product.recurrence = item[:recurrence]
        cart_product.recommended_by = item[:recommended_by]
        cart_product.rent = item[:rent]
        cart_product.url_parameters = item[:url_parameters]
        cart_product.referrer = item[:referrer]
        cart_product.recommender_model_name = item[:recommender_model_name]
        cart_product.call_start_time = item[:call_start_time].present? ? Time.zone.parse(item[:call_start_time]) : nil
        cart_product.pay_in_installments = !!item[:pay_in_installments] && product.allow_installment_plan?
        cart_product.save!
        cart_product
      end

      cart.alive_cart_products.where.not(id: updated_cart_products.map(&:id)).find_each(&:mark_deleted!)
    end

    head :no_content
  rescue ActiveRecord::RecordInvalid => e
    Bugsnag.notify(e)
    Rails.logger.error(e.full_message) if Rails.env.development?
    render json: { error: "Sorry, something went wrong. Please try again." }, status: :unprocessable_entity
  end

  private
    def permitted_cart_params
      params.require(:cart).permit(
        :email, :returnUrl, :rejectPppDiscount,
        discountCodes: [:code, :fromUrl],
        items: [
          :option_id, :affiliate_id, :price, :quantity, :recurrence, :recommended_by, :rent,
          :referrer, :recommender_model_name, :call_start_time, :pay_in_installments,
          url_parameters: {}, product: [:id], accepted_offer: [:id, :original_product_id, :original_variant_id],
        ]
      )
    end
end
