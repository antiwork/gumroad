# frozen_string_literal: true

class CheckoutController < ApplicationController
  layout "inertia"

  before_action :process_cart_id_param, only: [:show]

  def show
    cart_presenter = CartPresenter.new(logged_in_user:, ip: request.remote_ip, browser_guid: cookies[:_gumroad_guid])
    checkout_presenter = CheckoutPresenter.new(logged_in_user:, ip: request.remote_ip)

    render inertia: "Checkout/Show", props: {
      cart: -> { cart_presenter.cart_props },
      checkout: -> { checkout_presenter.checkout_props(params: checkout_params, browser_guid: cookies[:_gumroad_guid], cart: cart_presenter.cart) },
      recommended_products: InertiaRails.optional { recommended_products },
      # Carry the seller's accent colour through checkout so the buyer's journey does not go
      # seller-branded product page → Gumroad-pink payment screen → seller-branded content page
      # (gumroad-private#1493). Only the accent: see SellerProfile#accent_styles for why the
      # background and font are deliberately left as Gumroad's.
      #
      # nil for empty and multi-seller carts, in which case the page keeps the stock palette.
      accent_styles: -> { sole_seller_accent_styles(cart_presenter.cart) },
    }
  end

  def update
    # Guard against the rare case where `cart` is sent as a scalar (e.g. `cart=foo`);
    # `params.require(:cart)` would return the String unchanged and `.permit` would raise.
    unless params[:cart].respond_to?(:permit)
      return redirect_to checkout_path, alert: "Sorry, something went wrong. Please try again."
    end

    items = update_permitted_params[:items].to_a
    if items.length > Cart::MAX_ALLOWED_CART_PRODUCTS
      return redirect_to checkout_path, alert: "You cannot add more than #{Cart::MAX_ALLOWED_CART_PRODUCTS} products to the cart."
    end

    ActiveRecord::Base.transaction do
      browser_guid = cookies[:_gumroad_guid]
      cart = Cart.fetch_by(user: logged_in_user, browser_guid:) || Cart.new(user: logged_in_user, browser_guid:)
      cart.ip_address = request.remote_ip
      cart.browser_guid = browser_guid
      cart.email = logged_in_user&.email || update_permitted_params[:email].presence
      cart.return_url = update_permitted_params[:returnUrl]
      cart.reject_ppp_discount = update_permitted_params[:rejectPppDiscount] || false
      cart.discount_codes = update_permitted_params[:discountCodes].to_a.map { { code: _1[:code], fromUrl: _1[:fromUrl] } }
      cart.save!
      cart.lock!

      updated_cart_products = items.filter_map do |item|
        # The frontend sends quantity 0 to signal removal (ConfigurationSelector falls back to
        # `quantity ?? 0`). Skip those so they aren't persisted (quantity must be > 0) and let the
        # deletion step below clean up any existing matching record. Match a real numeric zero only:
        # a present-but-nonnumeric quantity ("abc") or a fractional one (0.5, which Integer() would
        # truncate to 0) is NOT a removal signal and must fall through to validation instead of
        # silently deleting the item.
        quantity = Integer(item[:quantity], exception: false) if item[:quantity].present?
        next if quantity&.zero? && item[:quantity].to_f.zero?

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
        # `url_parameters` and `referrer` are required by CartProduct (the former must be a JSON
        # object, the latter must be present). Some clients send a cart item without those keys at
        # all, in which case `item[:x]` is nil and a plain assignment would wipe the value the
        # record already has — including the empty hash CartProduct#assign_default_values just set
        # on a brand-new row, which then fails the JSON-schema validation and aborts the whole cart
        # save. Treat an absent key as "leave it alone" rather than "set it to nil"; a genuinely
        # missing referrer on a new item still fails validation, as it should.
        cart_product.url_parameters = item[:url_parameters] unless item[:url_parameters].nil?
        cart_product.referrer = item[:referrer] unless item[:referrer].nil?
        cart_product.recommender_model_name = item[:recommender_model_name]
        cart_product.call_start_time = item[:call_start_time].present? ? Time.zone.parse(item[:call_start_time]) : nil
        cart_product.pay_in_installments = !!item[:pay_in_installments] && product.allow_installment_plan?
        cart_product.save!
        cart_product
      end

      # Soft-deleting a stale cart product must not require it to be otherwise valid. Legacy/corrupt
      # records can have `quantity <= 0`, which would fail validation and abort the whole update, so
      # skip validations when removing them.
      cart.alive_cart_products.where.not(id: updated_cart_products.map(&:id)).find_each { _1.mark_deleted(validate: false) }
    end

    redirect_to checkout_path, status: :see_other
  rescue ActiveRecord::RecordInvalid, ActiveRecord::Deadlocked => e
    # Buyers occasionally submit absurd quantities or prices (for example by mashing digits)
    # that exceed the database column limits. Those are rejected by CartProduct's numericality
    # validations and the buyer already sees the alert below, so they are expected bad input
    # rather than an application bug — don't report each one to Sentry. Anything else (other
    # validation failures, deadlocks) still notifies as before.
    ErrorNotifier.notify(e) unless cart_product_out_of_range_error?(e)
    Rails.logger.error(e.full_message) if Rails.env.development?
    redirect_to checkout_path, alert: "Sorry, something went wrong. Please try again."
  end

  private
    # The seller accent CSS for this checkout, or nil when there is no single seller to take it from.
    #
    # The seller has to be resolved from the saved cart AND from the `?product=` parameter together,
    # because the two arrival paths carry the products differently and the page renders the union of
    # both. A buyer clicking "I want this!" on a product page lands on /checkout?product=<permalink>
    # with the product not yet persisted — the frontend merges it in from `checkout.add_products` and
    # only saves it to the cart afterwards, in a partial visit. Reading the saved cart alone would
    # therefore mean:
    #
    #   - a first-time buyer, who has no saved cart at all, never sees the seller's accent. That is
    #     exactly the product-page-to-payment-screen journey this is meant to fix, so the feature
    #     would be a no-op on its main path.
    #   - a buyer who already had seller X's product saved and clicks buy on seller Y's product page
    #     would get X's accent over a checkout showing both sellers' products, which is the
    #     misbranding the single-seller rule exists to prevent.
    #
    # So both sources are unioned, and the accent is used only when the union is exactly one seller.
    def sole_seller_accent_styles(cart)
      seller_ids = cart ? cart.visible_seller_ids : []
      seller_ids = (seller_ids + [arriving_product&.user_id]).compact.uniq
      return unless seller_ids.one?

      User.find_by(id: seller_ids.first)&.seller_profile&.accent_styles
    end

    # The product named by `?product=<permalink>`, resolved the same way CheckoutPresenter's
    # add_single_product_props resolves it, so the accent and the cart item rendered from that same
    # parameter cannot disagree about which seller this checkout is for.
    #
    # Guarded on String because the parameter is buyer-supplied and can arrive as a nested hash
    # (`?product[x]=y`), which the query builder cannot quote — see the "nested values" spec.
    def arriving_product
      return @arriving_product if defined?(@arriving_product)

      permalink = params[:product]
      return @arriving_product = nil unless permalink.is_a?(String) && permalink.present?

      @arriving_product = logged_in_user ? Link.fetch_leniently(permalink, user: logged_in_user) : Link.find_by_unique_permalink(permalink)
    end

    # True when the exception is a CartProduct validation failure caused ONLY by a
    # quantity or price above its column limit (see CartProduct::MAX_QUANTITY /
    # CartProduct::MAX_PRICE) — the known, expected shape of buyer-supplied bad input.
    # If the record has any other validation error alongside the out-of-range one,
    # that's unexpected and must still be reported, so we don't suppress it.
    def cart_product_out_of_range_error?(exception)
      return false unless exception.is_a?(ActiveRecord::RecordInvalid)

      record = exception.record
      return false unless record.is_a?(CartProduct)

      record.errors.any? && record.errors.all? { |error| error.attribute.in?([:quantity, :price]) && error.type == :less_than_or_equal_to }
    end

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

    RECOMMENDED_PRODUCTS_TIMEOUT_SECONDS = 10

    def recommended_products
      cart_product_ids = params[:cart_product_ids]
      cart_product_ids = [] unless cart_product_ids.is_a?(Array)

      args = {
        purchaser: logged_in_user,
        cart_product_ids: cart_product_ids.map { ObfuscateIds.decrypt(_1) },
        recommender_model_name: session[:recommender_model_name],
        limit: params[:limit].present? ? params[:limit].to_i : 6,
        recommendation_type: params[:recommendation_type],
      }

      Timeout.timeout(RECOMMENDED_PRODUCTS_TIMEOUT_SECONDS) do
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
    rescue Timeout::Error
      Rails.logger.warn("[CheckoutController] Recommended products timed out after #{RECOMMENDED_PRODUCTS_TIMEOUT_SECONDS}s")
      []
    end

    def checkout_params
      params.permit(
        :username, :product, :wishlist, :gift_wishlist_product,
        :accepted_offer_id, :affiliate_id, :recommended_by, :recommender_model_name,
        :option, :rent, :recurrence, :pay_in_installments, :price, :quantity,
        :call_start_time, :force_new_subscription
      )
    end

    def update_permitted_params
      @_update_permitted_params ||= params.require(:cart).permit(
        :email, :returnUrl, :rejectPppDiscount,
        discountCodes: [:code, :fromUrl],
        items: [
          :option_id, :affiliate_id, :price, :quantity, :recurrence, :recommended_by, :rent,
          :referrer, :recommender_model_name, :call_start_time, :pay_in_installments, :force_new_subscription,
          url_parameters: {}, product: [:id], accepted_offer: [:id, :original_product_id, :original_variant_id],
        ]
      )
    end
end
