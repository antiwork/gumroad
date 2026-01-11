# frozen_string_literal: true

class CheckoutController < ApplicationController
  before_action :process_cart_id_param, only: %i[index]

  def index
    @hide_layouts = true
    @on_checkout_page = true
    @checkout_presenter = CheckoutPresenter.new(logged_in_user:, ip: request.remote_ip)
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
end
