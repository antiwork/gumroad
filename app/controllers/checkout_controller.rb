# frozen_string_literal: true

class CheckoutController < ApplicationController
  layout "inertia"

  before_action :process_cart_id_param, only: [:show]

  def show
    render inertia: "Checkout/Show", props: {
      cart: -> { CartPresenter.new(logged_in_user:, ip: request.remote_ip, browser_guid: cookies[:_gumroad_guid]).cart_props },
      checkout: -> { CheckoutPresenter.new(logged_in_user:, ip: request.remote_ip).checkout_props(params:, browser_guid: cookies[:_gumroad_guid]) },
      recommended_products: InertiaRails.optional { recommended_products },
    }
  end

  def update
    if update_permitted_params[:items].length > Cart::MAX_ALLOWED_CART_PRODUCTS
      return redirect_to checkout_path, alert: "You cannot add more than #{Cart::MAX_ALLOWED_CART_PRODUCTS} products to the cart."
    end

    ActiveRecord::Base.transaction do
      browser_guid = cookies[:_gumroad_guid]
      cart = Cart.fetch_by(user: logged_in_user, browser_guid:) || Cart.new(user: logged_in_user, browser_guid:)
      cart.ip_address = request.remote_ip
      cart.browser_guid = browser_guid
      cart.email = update_permitted_params[:email].presence || logged_in_user&.email
      cart.return_url = update_permitted_params[:returnUrl]
      cart.reject_ppp_discount = update_permitted_params[:rejectPppDiscount] || false
      cart.discount_codes = update_permitted_params[:discountCodes].map { { code: _1[:code], fromUrl: _1[:fromUrl] } }
      cart.save!

      updated_cart_products = update_permitted_params[:items].map do |item|
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

    redirect_to checkout_path, status: :see_other
  rescue ActiveRecord::RecordInvalid => e
    Bugsnag.notify(e)
    Rails.logger.error(e.full_message) if Rails.env.development?
    redirect_to checkout_path, alert: "Sorry, something went wrong. Please try again."
  end

  private
    def process_cart_id_param
      return if params[:cart_id].blank?

      request_path_except_cart_id_param = "#{request.path}?#{request.query_parameters.except(:cart_id).merge(referrer: UrlService.discover_domain_with_protocol).to_query}"

      # Always show their own cart to the logged-in user
      return redirect_to(request_path_except_cart_id_param) if logged_in_user.present?

      cart = Cart.includes(:user).alive.find_by_secure_external_id(params[:cart_id], scope: "cart_login")
      return redirect_to(request_path_except_cart_id_param) if cart.nil?

      # Prompt the user to log in if the cart matching the `cart_id` param is associated with a user
      return redirect_to login_url(next: request_path_except_cart_id_param, email: cart.user.email), alert: "Please log in to complete checkout." if cart.user.present?

      browser_guid = cookies[:_gumroad_guid]
      if cart.browser_guid != browser_guid
        # Merge the guest cart for the current `browser_guid` with the cart matching the `cart_id` param
        MergeCartsService.new(
          source_cart: Cart.fetch_by(user: nil, browser_guid:),
          target_cart: cart,
          browser_guid:
        ).process
      end

      redirect_to(request_path_except_cart_id_param)
    end

    def analytics_enabled?
      true
    end

    def recommended_products
      args = {
        purchaser: logged_in_user,
        cart_product_ids: params.fetch(:cart_product_ids, []).map { ObfuscateIds.decrypt(_1) },
        recommender_model_name: session[:recommender_model_name],
        limit: params[:limit].present? ? params[:limit].to_i : 6,
        recommendation_type: params[:recommendation_type],
      }

      RecommendedProducts::CheckoutService.fetch_for_cart(**args).map do |product_info|
        ProductPresenter.card_for_web(
          product: product_info.product,
          request:,
          recommended_by: product_info.recommended_by,
          target: product_info.target,
          recommender_model_name: product_info.recommender_model_name,
          affiliate_id: product_info.affiliate_id,
        )
      end
    end

    def update_permitted_params
      @_update_permitted_params ||= params.require(:cart).permit(
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
