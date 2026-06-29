# frozen_string_literal: true

# Chooses the Stripe checkout payment integration for the current checkout props.
#
# The first Stripe Payment Element rollout keeps Rails on the existing
# stripe_payment_method_id charge path, so this presenter only decides whether
# checkout may render Payment Element or must fall back to CardElement.
class Checkout::StripePaymentPresenter
  STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME = :stripe_payment_element_checkout
  STRIPE_CARD_ELEMENT_INTEGRATION = "card_element"
  STRIPE_PAYMENT_ELEMENT_INTEGRATION = "payment_element"
  # Passed through to Stripe Elements as `mode`; these are Stripe's UI configuration values,
  # not a selector for Gumroad's backend PaymentIntent/SetupIntent API path.
  STRIPE_ELEMENTS_MODE_FOR_PAYMENT_INTENT = "payment"
  STRIPE_ELEMENTS_MODE_FOR_SETUP_INTENT = "setup"

  attr_reader :cart, :add_products, :clear_cart, :saved_credit_card

  def initialize(cart:, add_products:, clear_cart:, saved_credit_card:)
    @cart = cart
    @add_products = add_products
    @clear_cart = clear_cart
    @saved_credit_card = saved_credit_card
  end

  def props
    checkout_items = items
    fallback_reason = fallback_reason_for(checkout_items)
    return card_element_props(fallback_reason) if fallback_reason.present?

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
      checkout_items = []
      checkout_items.concat(cart_items) unless clear_cart
      checkout_items.concat(add_product_items)
    end

    def card_element_props(fallback_reason)
      {
        integration: STRIPE_CARD_ELEMENT_INTEGRATION,
        fallback_reason:,
        elements_options: nil,
      }
    end

    def payment_element_props(stripe_elements_mode)
      {
        integration: STRIPE_PAYMENT_ELEMENT_INTEGRATION,
        fallback_reason: nil,
        elements_options: {
          stripe_elements_mode:,
          currency: "usd",
          payment_method_types: ["card"],
          payment_method_creation: "manual",
        },
      }
    end

    def fallback_reason_for(items)
      return "empty_cart" if items.empty?

      sellers = items.map { _1[:seller] }.uniq
      return "unknown_seller" if sellers.any?(&:blank?)
      return "stripe_payment_element_flag_disabled" unless sellers.all? { Feature.active?(STRIPE_PAYMENT_ELEMENT_CHECKOUT_FEATURE_NAME, _1) }
      return "setup_or_installment_flow" if items.any? { _1[:pay_in_installments] }
      return nil if sellers.one? && setup_for_future_charges_without_charging?(items)
      return "setup_or_installment_flow" if items.any? { future_charge_setup_item?(_1) }
      return "not_charged" unless items.sum { _1[:price_cents].to_i }.positive?

      nil
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
        item(
          seller: cart_product.product.user,
          price_cents: cart_product.price,
          recurrence: cart_product.recurrence,
          pay_in_installments: cart_product.pay_in_installments,
          is_preorder: cart_product.product.is_in_preorder_state,
          has_free_trial: cart_product.product.free_trial_enabled,
          native_type: cart_product.product.native_type
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
          native_type: product[:native_type]
        )
      end
    end

    def item(seller:, price_cents:, recurrence:, pay_in_installments:, is_preorder:, has_free_trial:, native_type:)
      {
        seller:,
        price_cents:,
        recurrence:,
        pay_in_installments:,
        is_preorder:,
        has_free_trial:,
        native_type:,
      }
    end
end
