# frozen_string_literal: true

class OrdersController < ApplicationController
  include ValidateRecaptcha, Events, Order::ResponseHelpers, ClientConfirmedOrderFinalization

  # Long enough for a buyer to work through an image challenge, short enough that an offer cannot
  # be banked for later.
  RECAPTCHA_CHALLENGE_OFFER_TTL = 15.minutes

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
    offer_codes = offer_codes_after_payment(order, offer_codes, purchase_responses, order_params[:line_items])

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
      # The signed method list this checkout page mounted its Element with. Same reason as the
      # ConfirmationToken above for keeping it out of permitted_order_params: only this endpoint
      # accepts it. Verified (not trusted) in Order::PreparePaymentIntentService.
      payment_method_list_token: params[:payment_method_list_token].presence,
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
    offer_codes = offer_codes_after_payment(order, offer_codes, purchase_responses, order_params[:line_items])

    record_purchase_events(order)

    render json: { success: true, line_items: purchase_responses, offer_codes:, can_buyer_sign_up: }
  end

  # Finalizes a client-confirm PaymentIntent without re-charging.
  def finalize
    ActiveRecord::Base.connection.stick_to_primary!

    order = Order.find_by_secure_external_id(params[:id], scope: "confirm")
    e404 unless order

    finalize_responses, _, offer_codes = finalize_client_confirmed_order(
      order,
      retry_offer_codes: params[:retry_offer_codes]
    )

    render json: { success: true, line_items: finalize_responses, offer_codes:, can_buyer_sign_up: }
  end

  # Records browser-only Stripe confirmation failures and releases attempts that Stripe still
  # confirms are safely pre-charge.
  CONFIRM_ERROR_NOTIFY_LIMIT_PER_ORDER = 5
  CONFIRM_ERROR_NOTIFY_LIMIT_WINDOW = 1.hour
  CONFIRM_ERROR_CLEANUP_LIMIT_WINDOW = 5.minutes

  def confirm_error
    # `prepare` just created this order, so the replica can be behind when Stripe returns an error.
    ActiveRecord::Base.connection.stick_to_primary!

    order = Order.find_by_secure_external_id(params[:id], scope: "confirm")
    e404 unless order

    error_details = {
      order_id: order.id,
      stage: params[:stage].to_s.first(50),
      payment_method_type: params[:payment_method_type].to_s.first(50),
      selected_payment_method_type: params[:selected_payment_method_type].to_s.first(50),
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
    #
    # Splitting the issue per method would read better but must not key on this
    # attacker-controlled param; a bounded split is tracked in gumroad-private#1514.
    if confirm_error_reportable?(error_details) && confirm_error_notify_allowed?(order)
      ErrorNotifier.notify("Client-confirm browser error", **error_details)
    end

    cleanup_succeeded = release_failed_client_confirmation(
      order,
      processor_intent_id: params[:processor_intent_id].to_s.first(100).presence
    )
    unavailable_once_per_cart_ids = unavailable_once_per_cart_offer_code_ids(order)

    render json: {
      success: true,
      reservations_released: cleanup_succeeded && unavailable_once_per_cart_ids.empty?,
      unavailable_once_per_cart_ids:,
    }
  end

  private
    def release_failed_client_confirmation(order, processor_intent_id:)
      checked_intent_id = nil
      purchase = order.purchases.active_once_per_cart_offer_code_reservations.find do
        intent_ids = [_1.processor_payment_intent_id, _1.processor_setup_intent_id].compact
        intent_ids.any? && (processor_intent_id.nil? || intent_ids.include?(processor_intent_id))
      end
      return false unless purchase

      payment_intent = purchase.processor_payment_intent_id.present?
      checked_intent_id = payment_intent ? purchase.processor_payment_intent_id : purchase.processor_setup_intent_id
      return false unless confirm_error_cleanup_allowed?(order, checked_intent_id)

      intent = if payment_intent
        ChargeProcessor.get_charge_intent(purchase.merchant_account, checked_intent_id)
      else
        ChargeProcessor.get_setup_intent(purchase.merchant_account, checked_intent_id)
      end
      status = payment_intent ? intent.payment_intent.status : intent.setup_intent.status
      safe_statuses = [
        StripeIntentStatus::REQUIRES_PAYMENT_METHOD,
        StripeIntentStatus::REQUIRES_CONFIRMATION,
        StripeIntentStatus::CANCELED,
      ]
      # Keep the claim for intents that can still settle. Webhooks own their final outcome, and
      # releasing it here would turn confirm_error into an unbounded processor polling endpoint.
      return false unless status.in?(safe_statuses)

      if status == StripeIntentStatus::CANCELED
        Purchase::MarkFailedService.new(purchase).perform
        purchase.charge&.destroy_presentment_records! if payment_intent
      elsif payment_intent
        purchase.cancel_charge_intent!
      else
        purchase.cancel_setup_intent!
      end
      order.purchases.in_progress.find_each do |other_purchase|
        other_intent_id = payment_intent ? other_purchase.processor_payment_intent_id : other_purchase.processor_setup_intent_id
        Purchase::MarkFailedService.new(other_purchase).perform if other_intent_id == checked_intent_id
      end
      true
    rescue ChargeProcessorError => e
      Rails.cache.delete(confirm_error_cleanup_key(order, checked_intent_id)) if checked_intent_id
      ErrorNotifier.notify(e) { _1.add_metadata(:order, { id: order.id }) }
      false
    end

    def confirm_error_cleanup_allowed?(order, processor_intent_id)
      claimed = Rails.cache.write(
        confirm_error_cleanup_key(order, processor_intent_id),
        true,
        expires_in: CONFIRM_ERROR_CLEANUP_LIMIT_WINDOW,
        unless_exist: true
      )
      claimed.nil? || claimed
    end

    def confirm_error_cleanup_key(order, processor_intent_id)
      "confirm_error_cleanup:#{order.id}:#{processor_intent_id}"
    end

    def unavailable_once_per_cart_offer_code_ids(order)
      associations = { purchase_offer_code_discount: :offer_code }
      active_reservations = order.purchases.active_once_per_cart_offer_code_reservations.includes(associations)
      completed_uses = order.purchases.completed_once_per_cart_allocation_uses.includes(associations)
      (active_reservations + completed_uses)
        .uniq
        .filter_map do |purchase|
          offer_code = purchase.purchase_offer_code_discount.offer_code
          offer_code.external_id if offer_code.max_purchase_count.present?
        end
        .uniq
    end

    def offer_codes_after_payment(order, offer_codes, purchase_responses, line_items)
      line_items = Array(line_items)
      candidates = Order::OfferCodeRecoveryService.merge_responses(
        offer_codes,
        Order::OfferCodeRecoveryService.for_order(order)
      )
      retry_line_items = line_items.select { purchase_responses.dig(_1[:uid], :success) != true }
      payment_confirmation_pending = purchase_responses.any? do |_uid, response|
        response[:requires_card_action] || response[:requires_card_setup] || response[:requires_payment_confirmation]
      end

      preserved = candidates.filter_map do |response|
        products = response[:products].reject { |_permalink, discount| discount[:once_per_cart] }
        { code: response[:code], products: } if products.any?
      end
      revalidated = candidates.filter_map do |response|
        permalinks = response[:products].filter_map do |permalink, discount|
          permalink if discount[:once_per_cart]
        end
        products = retry_line_items.filter_map do |line_item|
          next unless permalinks.include?(line_item[:permalink])
          [line_item[:uid], line_item.slice(:permalink, :quantity, :price_cents, :tip_cents)]
        end.to_h
        next if products.empty?

        service = OfferCodeDiscountComputingService.new(
          response[:code],
          products,
          buyer: logged_in_user,
          key_by_input: true,
          excluding_order: payment_confirmation_pending ? order : nil
        )
        result = service.process
        next if result[:error_code].present?

        discounts = result[:products_data].filter_map do |line_item_uid, data|
          next unless data.dig(:discount, :once_per_cart)
          line_item = retry_line_items.find { _1[:uid] == line_item_uid }
          [line_item[:permalink], data[:discount]] if line_item
        end.to_h
        { code: response[:code], products: discounts } if discounts.any?
      end

      Order::OfferCodeRecoveryService.merge_responses(preserved, revalidated)
    end

    # Methods that confirm in-page: a failed attempt transitions the intent, so
    # `payment_intent.payment_failed` fires and `Purchase::ChargeEventsHandler#handle_event_failed!`
    # writes the code to `purchases.stripe_error_code`.
    #
    # `apple_pay`/`google_pay` are here because they are how the Payment Element names a wallet ROW
    # (see `isWalletPaymentElementType`), and only the selected-row fallback below ever carries
    # them — the resulting PaymentMethod is a card, so Stripe's own value says `card`.
    CONFIRM_ERROR_SERVER_RECORDED_PAYMENT_METHOD_TYPES = %w[card link apple_pay google_pay].freeze

    # The error type that proves a charge was actually attempted, and therefore that
    # `payment_intent.payment_failed` fired at all.
    CONFIRM_ERROR_ATTEMPTED_STRIPE_ERROR_TYPE = "card_error"

    # Codes that prove the same thing when the type does not. Stripe's `type` describes the shape
    # of the API rejection, so `invalid_request_error` covers both "your request was malformed"
    # (no charge, no webhook) and "this intent already failed authentication" (charge attempted,
    # webhook fired).
    #
    # Exact match, not a prefix: the browser posts Stripe.js's raw `error.code`, never the
    # `_<decline_code>` form the server composes, so a prefix buys nothing here — and it would
    # silently suppress a future Stripe code that merely extends one of these, which is the
    # opposite of the fail-open rule the denylist below follows.
    #
    # `payment_intent_unexpected_state` and `payment_intent_mandate_invalid` are deliberately
    # absent — both are confirm-time rejections that never transition the intent, so nothing else
    # records them and they must keep reporting.
    CONFIRM_ERROR_ATTEMPTED_STRIPE_ERROR_CODES = %w[
      payment_intent_authentication_failure
      payment_intent_payment_attempt_failed
    ].freeze

    # Report only failures nothing else records.
    #
    # Both conditions are required. Stripe attaches `payment_method` to any error involving one,
    # not just to declines, so a card-typed `invalid_request_error` (consumed ConfirmationToken,
    # intent in an unexpected state) never transitions the intent and never webhooks. Suppressing
    # on the method alone would make those log-only.
    #
    # `payment_method_type` comes from Stripe's error object and is ABSENT on most declines — it is
    # only set when Stripe attached a payment method to the error, which a plain issuer decline
    # does not. So the buyer's selected Payment Element row is the fallback: without it a card
    # decline is indistinguishable from a redirect-leg failure and every one of them reports
    # (gumroad-private#1514). Stripe's value wins when present; the two disagreeing is itself worth
    # seeing, and Stripe is the authority on what it actually charged.
    #
    # Denylist rather than allowlist so an unrecognised or blank type keeps reporting: a method
    # added later must not go unmonitored because nobody updated this list, and a buyer who
    # suppresses their own report only loses their own signal.
    def confirm_error_reportable?(error_details)
      return true unless confirm_error_charge_attempted?(error_details)

      method_type = error_details[:payment_method_type].presence ||
                    error_details[:selected_payment_method_type]
      !method_type.in?(CONFIRM_ERROR_SERVER_RECORDED_PAYMENT_METHOD_TYPES)
    end

    # Whether a charge was attempted. Deliberately not a `purchases.stripe_error_code` lookup:
    # that write arrives anywhere from 0 to ~690s after the browser posts here, so reading the row
    # would suppress or report by luck of the race.
    def confirm_error_charge_attempted?(error_details)
      return true if error_details[:stripe_error_type] == CONFIRM_ERROR_ATTEMPTED_STRIPE_ERROR_TYPE

      error_details[:stripe_error_code].in?(CONFIRM_ERROR_ATTEMPTED_STRIPE_ERROR_CODES)
    end

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

      if params[:line_items].is_a?(Array) && params[:line_items].length > Cart::MAX_ALLOWED_CART_PRODUCTS
        return render_error("You cannot add more than #{Cart::MAX_ALLOWED_CART_PRODUCTS} products to the cart.")
      end

      # Don't allow the order to go through if cookies are disabled and it's a paid order
      contains_paid_purchase = if params[:line_items].present?
        params[:line_items].any? { |product_params| product_params[:perceived_price_cents] != "0" }
      else
        params[:perceived_price_cents] != "0"
      end
      browser_guid = cookies[:_gumroad_guid]
      return render_error("Cookies are not enabled on your browser. Please enable cookies and refresh this page before continuing.") if contains_paid_purchase && browser_guid.blank?

      # Verify reCAPTCHA response
      if !skip_recaptcha? && !valid_checkout_recaptcha?
        render_error(recaptcha_failure_message, recaptcha_challenge_available: offer_recaptcha_challenge_fallback?)
      end
    end

    def valid_checkout_recaptcha?
      fallback = recaptcha_challenge_fallback?
      valid_recaptcha_response_and_hostname?(
        site_key: CheckoutRecaptcha.site_key(logged_in_user, challenge_fallback: fallback),
        surface: CheckoutRecaptcha.surface(logged_in_user, challenge_fallback: fallback)
      )
    end

    # The buyer is resubmitting with a token from the challenge key after being refused on score
    # alone, so verify against that key instead (gumroad-private#1590). The marker is only honoured
    # against an offer this server issued and has not yet spent: :checkout carries no score
    # threshold, so a marker taken on trust would let any cohort buyer opt out of the score gate on
    # their FIRST attempt. Also ignored when the challenge key is unconfigured — verifying against a
    # blank key lands on the infrastructure-error path, which fails OPEN for :checkout.
    def recaptcha_challenge_fallback?
      return @recaptcha_challenge_fallback if defined?(@recaptcha_challenge_fallback)

      @recaptcha_challenge_fallback =
        ActiveModel::Type::Boolean.new.cast(params[:recaptcha_challenge_fallback]).present? &&
        CheckoutRecaptcha.challenge_site_key.present? &&
        redeem_recaptcha_challenge_offer?
    end

    # One redemption per issued offer. DEL returning 1 means this request is the one that spent it,
    # so concurrent submissions cannot both ride the same offer.
    def redeem_recaptcha_challenge_offer?
      browser_guid = cookies[:_gumroad_guid]
      return false if browser_guid.blank?

      $redis.del(RedisKey.recaptcha_challenge_offer(browser_guid)) == 1
    end

    # Offered once per order attempt, and only to the cohort whose key cannot render a challenge —
    # everyone else already checks out against the challenge key, so there is nothing to fall back
    # to. Recorded server-side because the marker on the next request is only trustworthy if we
    # issued it. A request that already spent an offer and still failed is terminal.
    def offer_recaptcha_challenge_fallback?
      # Without a challenge key the client would be told a challenge is available but handed no
      # key to render it with — advertising the offer would be a dead end all over again.
      return false if CheckoutRecaptcha.challenge_site_key.blank?
      return false unless CheckoutRecaptcha.score_based?(logged_in_user)
      return false unless recaptcha_failed_on_score_only? && !recaptcha_challenge_fallback?

      browser_guid = cookies[:_gumroad_guid]
      return false if browser_guid.blank?

      $redis.set(RedisKey.recaptcha_challenge_offer(browser_guid), "1", ex: RECAPTCHA_CHALLENGE_OFFER_TTL.to_i)
      true
    end

    def skip_recaptcha?
      site_key = CheckoutRecaptcha.site_key(logged_in_user)
      return true if (Rails.env.development? || Rails.env.test?) && site_key.blank?
      return true if action_name.in?(%w[create prepare]) && all_free_products_without_captcha?
      return true if valid_wallet_payment?

      false
    end

    def all_free_products_without_captcha?
      # An absent/blank :line_items must NOT earn the free-cart exemption — a vacuous
      # Array#all? would let a cartless request skip reCAPTCHA entirely. It also must not
      # 500: the old {} default handed #all? a bare ActionController::Parameters
      # (GUMROAD-7B), and an explicit-but-empty list deep-munges to nil.
      line_items = params.fetch(:line_items, [])
      return false if line_items.blank?

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
        :billing_agreement_id, :paypal_order_id, :stripe_payment_method_id, :stripe_customer_id, :stripe_setup_intent_id,
        :braintree_transient_customer_store_key, :braintree_device_data, :use_existing_card, :paymentToken,
        :url_parameters, :is_gift, :giftee_email, :giftee_id, :gift_note, :referrer, :buyer_currency_quote,
        # The browser reports a client-side tokenization/setup failure (e.g. a failed 3DS on the
        # setup-intent lane) as a hash; permitting it as a scalar silently dropped it and every
        # such failure surfaced as the generic CREDIT_CARD_NOT_PROVIDED decline copy.
        stripe_error: [:type, :message, :code, :charge, :decline_code],
        purchase: [:full_name, :street_address, :city, :state, :zip_code, :country],
        # Individual purchase params
        line_items: [:uid, :permalink, :perceived_price_cents, :price_range, :discount_code, :is_preorder, :quantity, :call_start_time,
                     :was_product_recommended, :recommended_by, :referrer, :is_rental, :is_multi_buy,
                     :was_discover_fee_charged, :price_cents, :tax_cents, :gumroad_tax_cents, :shipping_cents, :price_id, :affiliate_id, :url_parameters, :is_purchasing_power_parity_discounted, :accepts_purchasing_power_parity_discount,
                     :recommender_model_name, :tip_cents, :pay_in_installments, :force_new_subscription, :confirmed_duplicate_purchase,
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

    def render_error(error_message, purchase: nil, recaptcha_challenge_available: false)
      response = error_response(error_message, purchase:)
      # Only sent when the client actually has a next step, so an ordinary failure keeps today's
      # response shape byte for byte.
      response[:recaptcha_challenge_available] = true if recaptcha_challenge_available
      render json: response
    end

    def can_buyer_sign_up
      !logged_in_user && User.alive.where(email: params[:email]).none?
    end
end
