# frozen_string_literal: true

# Chooses between card, server-confirm Payment Element, and client-confirm Payment Element checkout.
class Checkout::StripePaymentPresenter
  include CurrencyHelper

  STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME = :stripe_payment_element_checkout
  STRIPE_PAYMENT_ELEMENT_LINK_FEATURE_NAME = :stripe_payment_element_link
  STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_FEATURE_NAME = :stripe_payment_element_client_confirm
  STRIPE_CARD_ELEMENT_INTEGRATION = "card_element"
  STRIPE_PAYMENT_ELEMENT_INTEGRATION = "payment_element"
  STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_INTEGRATION = "payment_element_client_confirm"
  # Passed through to Stripe Elements as `mode`; these are Stripe's UI configuration values,
  # not a selector for Gumroad's backend PaymentIntent/SetupIntent API path.
  STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT = "payment"
  STRIPE_ELEMENTS_MODE_FOR_SETUP_INTENT = "setup"
  # Payment Element mounts with a charge amount up front, unlike CardElement, so keep carts
  # below Stripe's USD charge floor on CardElement. This is intentionally lower than
  # Gumroad's buyer-facing minimum so chargeable near-zero carts can still use Payment Element.
  STRIPE_PAYMENT_ELEMENT_MINIMUM_USD_CHARGE_CENTS = 50
  # The client-confirm payment_method_types are computed per cart by Checkout::PaymentMethodResolver and
  # threaded into the deferred PaymentIntent by Order::PreparePaymentIntentService, so the Payment Element
  # and the intent cannot drift (Stripe rejects a payment_method_types-scoped ConfirmationToken against a
  # mismatched intent). Currency stays fixed here until buyer-currency charging lands (out of scope).
  CLIENT_CONFIRM_CURRENCY = "usd"

  attr_reader :cart, :add_products, :clear_cart, :saved_credit_card, :ip

  def initialize(cart:, add_products:, clear_cart:, saved_credit_card:, ip: nil)
    @cart = cart
    @add_products = add_products
    @clear_cart = clear_cart
    @saved_credit_card = saved_credit_card
    @ip = ip
  end

  def props
    checkout_items = items
    disable_wallets = checkout_items.any? { buyer_currency_presentment_candidate?(_1) }
    fallback_reason = fallback_reason_for(checkout_items)
    return card_element_props(fallback_reason, disable_wallets:) if fallback_reason.present?

    # Client-confirm eligible carts are always one-time charges, so check them before setup mode.
    return client_confirm_props if client_confirm_eligible?

    stripe_elements_mode =
      if setup_for_future_charges_without_charging?(checkout_items)
        STRIPE_ELEMENTS_MODE_FOR_SETUP_INTENT
      else
        STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT
      end
    payment_element_props(stripe_elements_mode)
  end

  private
    def items
      @items ||= begin
        checkout_items = []
        checkout_items.concat(cart_items) unless clear_cart
        checkout_items.concat(add_product_items)
      end
    end

    def sellers
      @sellers ||= items.map { _1[:seller] }.uniq
    end

    def card_element_props(fallback_reason, disable_wallets:)
      {
        integration: STRIPE_CARD_ELEMENT_INTEGRATION,
        fallback_reason:,
        disable_wallets:,
        elements_options: nil,
      }
    end

    def payment_element_props(stripe_elements_mode)
      {
        integration: STRIPE_PAYMENT_ELEMENT_INTEGRATION,
        fallback_reason: nil,
        disable_wallets: false,
        elements_options: {
          stripe_elements_mode:,
          currency: "usd",
          payment_method_types: ["card"],
          payment_method_creation: "manual",
          stripe_link_enabled: sellers.all? { Feature.active?(STRIPE_PAYMENT_ELEMENT_LINK_FEATURE_NAME, _1) },
        },
      }
    end

    # The Flipper flag is the activation switch for the client-confirm path; the resolver owns the
    # cart-shape policy (single-seller, non-connect, one-time). One ConfirmationToken funds one
    # PaymentIntent, so client-confirm is limited to one seller.
    def client_confirm_eligible?
      sellers.all? { Feature.active?(STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_FEATURE_NAME, _1) } &&
        payment_method_resolver.resolve.client_confirm_eligible?
    end

    def payment_method_resolver
      @payment_method_resolver ||= Checkout::PaymentMethodResolver.new(
        sellers:,
        recurring: items.any? { _1[:recurrence].present? },
        commission: items.any? { _1[:native_type] == Link::NATIVE_TYPE_COMMISSION },
        setup_for_future: setup_for_future_charges_without_charging?(items),
      )
    end

    def client_confirm_props
      resolution = payment_method_resolver.resolve
      {
        integration: STRIPE_PAYMENT_ELEMENT_CLIENT_CONFIRM_INTEGRATION,
        fallback_reason: nil,
        # Presentment candidates never reach client-confirm (they fall back to CardElement
        # above), so wallets stay enabled; emit the field so every integration variant
        # carries the same wallet contract the frontend reads.
        disable_wallets: false,
        elements_options: {
          stripe_elements_mode: STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT,
          currency: CLIENT_CONFIRM_CURRENCY,
          payment_method_types: resolution.payment_method_types,
          stripe_link_enabled: sellers.all? { Feature.active?(STRIPE_PAYMENT_ELEMENT_LINK_FEATURE_NAME, _1) },
          stripe_connect_account_id: resolution.stripe_connect_account_id,
        },
      }
    end

    def fallback_reason_for(items)
      return "empty_cart" if items.empty?
      return "unknown_seller" if sellers.any?(&:blank?)
      return "stripe_payment_element_flag_disabled" unless sellers.all? { Feature.active?(STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, _1) }
      return "setup_or_installment_flow" if items.any? { _1[:pay_in_installments] }
      return nil if sellers.one? && setup_for_future_charges_without_charging?(items)
      return "setup_or_installment_flow" if items.any? { future_charge_setup_item?(_1) }

      # Initial eligibility uses pre-tax item prices; the browser waits for the final loaded total.
      total_price_cents = items.sum { _1[:price_cents].to_i }
      return "not_charged" unless total_price_cents.positive?
      return "stripe_payment_element_amount_below_minimum" if total_price_cents < STRIPE_PAYMENT_ELEMENT_MINIMUM_USD_CHARGE_CENTS
      return "buyer_currency_presentment_unsupported" if items.any? { buyer_currency_presentment_candidate?(_1) }

      nil
    end

    def buyer_currency_presentment_candidate?(item)
      Checkout::BuyerCurrencyEligibility.buyer_presentment_candidate?(
        seller: item[:seller],
        buyer_currency_display: item[:buyer_currency_display]
      )
    end

    def setup_for_future_charges_without_charging?(items)
      items.all? { future_charge_setup_item?(_1) } && items.sum { _1[:price_cents].to_i }.positive?
    end

    def future_charge_setup_item?(item)
      item[:is_preorder] || item[:has_free_trial]
    end

    def cart_items
      return [] if cart.blank?

      cart.alive_cart_products.joins(:product).merge(Link.not_archived).includes(product: :user).map do |cart_product|
        product = cart_product.product
        item(
          seller: product.user,
          price_cents: cart_product.price,
          recurrence: cart_product.recurrence,
          pay_in_installments: cart_product.pay_in_installments,
          is_preorder: product.is_in_preorder_state,
          has_free_trial: product.free_trial_enabled,
          native_type: product.native_type,
          buyer_currency_display: buyer_currency_display_props(product:, price_cents: cart_product.price, ip:)
        )
      end
    end

    def add_product_items
      seller_ids = add_products.filter_map { _1.dig(:product, :creator, :id) }.uniq
      sellers_by_external_id = User.where(external_id: seller_ids).index_by(&:external_id)

      add_products.map do |checkout_product|
        product = checkout_product[:product]
        item(
          seller: sellers_by_external_id[product.dig(:creator, :id)],
          price_cents: checkout_product[:price],
          recurrence: checkout_product[:recurrence],
          pay_in_installments: checkout_product[:pay_in_installments],
          is_preorder: product[:is_preorder],
          has_free_trial: product[:free_trial].present?,
          native_type: product[:native_type],
          buyer_currency_display: product[:buyer_currency_display]
        )
      end
    end

    def item(seller:, price_cents:, recurrence:, pay_in_installments:, is_preorder:, has_free_trial:, native_type:, buyer_currency_display:)
      {
        seller:,
        price_cents:,
        recurrence:,
        pay_in_installments:,
        is_preorder:,
        has_free_trial:,
        native_type:,
        buyer_currency_display:,
      }
    end
end
