# frozen_string_literal: true

class OrdersController < ApplicationController
  include ValidateRecaptcha, Events, Order::ResponseHelpers, ClientConfirmedOrderFinalization

  before_action :normalize_line_items, only: [:create, :prepare]
  before_action :validate_order_request, only: [:create, :prepare]
  before_action :fetch_affiliates, only: [:create, :prepare]

  def create
    order_params = build_order_params

    order, purchase_responses, offer_codes = Order::CreateService.new(
      buyer: logged_in_user,
      params: order_params
    ).perform

    charge_responses = Order::ChargeService.new(order:, params: order_params).perform

    attribute_utm_link_sale(order, order_params[:browser_guid])

    purchase_responses.merge!(charge_responses)

    order.purchases.each { create_purchase_event_and_recommendation_info(_1) }
    order.send_charge_receipts unless purchase_responses.any? { |_k, v| v[:requires_card_action] || v[:requires_card_setup] }

    render json: { success: true, line_items: purchase_responses, offer_codes:, can_buyer_sign_up: }
  end

  def confirm
    ActiveRecord::Base.connection.stick_to_primary!

    order = Order.find_by_secure_external_id(params[:id], scope: "confirm")
    e404 unless order

    confirm_responses, offer_codes = Order::ConfirmService.new(order:, params:).perform

    confirm_responses.each do |purchase_id, response|
      next unless response[:success]

      purchase = Purchase.find(purchase_id)
      create_purchase_event_and_recommendation_info(purchase)
    end
    order.send_charge_receipts

    render json: { success: true, line_items: confirm_responses, offer_codes:, can_buyer_sign_up: }
  end

  # Starts client-confirm Payment Element checkout by returning an unconfirmed PaymentIntent.
  def prepare
    # The ConfirmationToken is deliberately absent from permitted_order_params: only this endpoint
    # accepts it, so #create requests can never carry one. It is merged here so purchase creation
    # can record the client-confirm lane in the purchase's payment-flow analytics row.
    order_params = build_order_params.merge(
      confirmation_token: params[:confirmation_token].presence,
      payment_element_mount_currency: params[:payment_element_mount_currency].presence,
    )

    order, purchase_responses, offer_codes = Order::CreateService.new(
      buyer: logged_in_user,
      params: order_params
    ).perform

    prepare_responses = Order::PreparePaymentIntentService.new(
      order:,
      params: order_params,
      confirmation_token: params[:confirmation_token]
    ).perform

    purchase_responses.merge!(prepare_responses)

    record_purchase_events(order)

    render json: { success: true, line_items: purchase_responses, offer_codes:, can_buyer_sign_up: }
  end

  # Finalizes a client-confirm PaymentIntent without re-charging.
  def finalize
    ActiveRecord::Base.connection.stick_to_primary!

    order = Order.find_by_secure_external_id(params[:id], scope: "confirm")
    e404 unless order

    finalize_responses, = finalize_client_confirmed_order(order)

    render json: { success: true, line_items: finalize_responses, offer_codes: [], can_buyer_sign_up: }
  end

  # Records a client-side stripe.confirmPayment failure so redirect-based payment methods
  # (iDEAL, Bancontact — methods that leave the page to authenticate at the buyer's bank) are
  # debuggable in production. The browser is the ONLY place that ever sees these errors: a
  # rejected confirm on a redirect method happens before any charge exists, so no
  # payment_failed webhook fires and the purchase just sits in_progress until the abandonment
  # sweeper cancels it — server-side, a buyer who hit a hard confirm error is
  # indistinguishable from one who simply closed the tab (the failure mode behind the
  # 2026-07-23 iDEAL ramp-down, gumroad-private#933: zero completions and zero server-side
  # evidence of why). The order token proves the caller owns a real prepared order, the
  # payload is size-capped below, and Sentry reports are rate-limited per order, so this
  # can't be used to spam Sentry with arbitrary junk.
  CONFIRM_ERROR_NOTIFY_LIMIT_PER_ORDER = 5
  CONFIRM_ERROR_NOTIFY_LIMIT_WINDOW = 1.hour

  def confirm_error
    # `prepare` just created this order, so the replica can be behind when Stripe returns an error.
    ActiveRecord::Base.connection.stick_to_primary!

    order = Order.find_by_secure_external_id(params[:id], scope: "confirm")
    e404 unless order

    error_details = {
      order_id: order.id,
      stage: params[:stage].to_s.first(50),
      payment_method_type: params[:payment_method_type].to_s.first(50),
      stripe_error_type: params[:stripe_error_type].to_s.first(100),
      stripe_error_code: params[:stripe_error_code].to_s.first(100),
      stripe_error_message: params[:stripe_error_message].to_s.first(500),
    }
    Rails.logger.error("Client-confirm browser error for order #{order.id}: #{error_details.inspect}")

    # A fixed message keeps every report in one Sentry issue (the Stripe code lives in the
    # event context, not the title), and the per-order counter caps how many events a single
    # order token can emit — payload size caps alone don't bound the NUMBER of events, so a
    # scripted caller replaying a valid token could otherwise flood Sentry. The log line
    # above stays unconditional so full forensics are always in the logs.
    if confirm_error_notify_allowed?(order)
      ErrorNotifier.notify("Client-confirm browser error", **error_details)
    end

    render json: { success: true }
  end

  private
    # Fail-open per-order throttle for confirm_error Sentry reports. Counts reports per order
    # in a short cache window; once the cap is hit we keep logging but stop notifying, so a
    # buyer (or script) replaying the same valid order token can't flood Sentry with events.
    # Fail-open (nil counter => allow) because losing a rate-limit beat is better than losing
    # the forensic signal this endpoint exists to capture.
    def confirm_error_notify_allowed?(order)
      count = Rails.cache.increment(
        "confirm_error_notify_count:#{order.id}",
        1,
        expires_in: CONFIRM_ERROR_NOTIFY_LIMIT_WINDOW
      )
      count.nil? || count <= CONFIRM_ERROR_NOTIFY_LIMIT_PER_ORDER
    end

    def build_order_params
      permitted_order_params.merge!(
        browser_guid: cookies[:_gumroad_guid],
        session_id: session.id,
        ip_address: request.remote_ip,
        is_mobile: is_mobile?
      ).to_h
    end

    def normalize_line_items
      if params[:line_items].is_a?(ActionController::Parameters)
        params[:line_items] = params[:line_items].values
      end
    end

    def validate_order_request
      # Don't allow the order to go through if the buyer is a bot. Pretend that the order succeeded instead.
      return render json: { success: true } if is_bot?

      # Don't allow the order to go through if cookies are disabled and it's a paid order
      contains_paid_purchase = if params[:line_items].present?
        params[:line_items].any? { |product_params| product_params[:perceived_price_cents] != "0" }
      else
        params[:perceived_price_cents] != "0"
      end
      browser_guid = cookies[:_gumroad_guid]
      return render_error("Cookies are not enabled on your browser. Please enable cookies and refresh this page before continuing.") if contains_paid_purchase && browser_guid.blank?

      # Verify reCAPTCHA response
      if !skip_recaptcha? && !valid_recaptcha_response_and_hostname?(site_key: CheckoutRecaptcha.site_key(logged_in_user), surface: CheckoutRecaptcha.surface(logged_in_user))
        render_error(ValidateRecaptcha::CAPTCHA_FAILURE_MESSAGE)
      end
    end

    def skip_recaptcha?
      site_key = CheckoutRecaptcha.site_key(logged_in_user)
      return true if (Rails.env.development? || Rails.env.test?) && site_key.blank?
      return true if action_name.in?(%w[create prepare]) && all_free_products_without_captcha?
      return true if valid_wallet_payment?

      false
    end

    def all_free_products_without_captcha?
      line_items = params.fetch(:line_items, {})
      line_items.all? do |product|
        product_link = Link.find_by(unique_permalink: product["permalink"])
        !product_link.require_captcha? && product["perceived_price_cents"].to_s == "0"
      end
    end

    def valid_wallet_payment?
      return false if [params[:wallet_type], params[:stripe_payment_method_id]].any?(&:blank?)
      payment_method = Stripe::PaymentMethod.retrieve(params[:stripe_payment_method_id])
      payment_method&.card&.wallet&.type == params[:wallet_type]
    rescue Stripe::StripeError
      render_error("Sorry, something went wrong.")
    end

    def permitted_order_params
      params.permit(
        # Common params across all purchases of the order
        :friend, :locale, :plugins, :save_card, :card_data_handling_mode, :card_data_handling_error,
        :card_country, :card_country_source, :wallet_type, :payment_details_source, :cc_zipcode, :vat_id, :email, :tax_country_election,
        :save_shipping_address, :card_expiry_month, :card_expiry_year, :stripe_status, :visual,
        :billing_agreement_id, :paypal_order_id, :stripe_payment_method_id, :stripe_customer_id, :stripe_setup_intent_id, :stripe_error,
        :braintree_transient_customer_store_key, :braintree_device_data, :use_existing_card, :paymentToken,
        :url_parameters, :is_gift, :giftee_email, :giftee_id, :gift_note, :referrer, :buyer_currency_quote,
        purchase: [:full_name, :street_address, :city, :state, :zip_code, :country],
        # Individual purchase params
        line_items: [:uid, :permalink, :perceived_price_cents, :price_range, :discount_code, :is_preorder, :quantity, :call_start_time,
                     :was_product_recommended, :recommended_by, :referrer, :is_rental, :is_multi_buy,
                     :was_discover_fee_charged, :price_cents, :tax_cents, :gumroad_tax_cents, :shipping_cents, :price_id, :affiliate_id, :url_parameters, :is_purchasing_power_parity_discounted,
                     :recommender_model_name, :tip_cents, :pay_in_installments, :force_new_subscription,
                     custom_fields: [:id, :value], variants: [], perceived_free_trial_duration: [:unit, :amount], accepted_offer: [:id, :original_variant_id, :original_product_id],
                     bundle_products: [:product_id, :variant_id, :quantity, custom_fields: [:id, :value]]])
    end

    def fetch_affiliates
      line_items = params.fetch(:line_items, [])
      line_items.each do |line_item_params|
        product = Link.find_by(unique_permalink: line_item_params[:permalink])

        # In the case a purchase is both recommended and has an affiliate, recommendation takes priority
        # so don't include the affiliate unless it is a global affiliate
        affiliate = fetch_affiliate(product, line_item_params)
        line_item_params.delete(:affiliate_id)
        line_item_params[:affiliate_id] = affiliate.id if affiliate&.eligible_for_purchase_credit?(product:, was_recommended: line_item_params[:was_product_recommended] && line_item_params[:recommended_by] != RecommendationType::GUMROAD_MORE_LIKE_THIS_RECOMMENDATION, purchaser_email: params[:email])
      end
    end

    def render_error(error_message, purchase: nil)
      render json: error_response(error_message, purchase:)
    end

    def can_buyer_sign_up
      !logged_in_user && User.alive.where(email: params[:email]).none?
    end
end
