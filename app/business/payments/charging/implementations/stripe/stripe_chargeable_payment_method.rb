# frozen_string_literal: true

class StripeChargeablePaymentMethod
  include StripeErrorHandler

  attr_reader :payment_method_id, :stripe_setup_intent_id, :stripe_payment_intent_id

  def initialize(payment_method_id, customer_id: nil,
                 stripe_setup_intent_id: nil,
                 stripe_payment_intent_id: nil,
                 zip_code:, product_permalink:)
    @payment_method_id = payment_method_id
    @customer_id = customer_id
    @stripe_setup_intent_id = stripe_setup_intent_id
    @stripe_payment_intent_id = stripe_payment_intent_id
    @zip_code = zip_code
    @merchant_account = get_merchant_account(product_permalink)
  end

  def charge_processor_id
    StripeChargeProcessor.charge_processor_id
  end

  def prepare!
    if @payment_method.present?
      @customer_id ||= @payment_method.customer
      return true
    end

    with_stripe_error_handler do
      @payment_method = Stripe::PaymentMethod.retrieve(@payment_method_id)
    end

    @customer_id ||= @payment_method.customer

    prepare_for_direct_charge if @merchant_account&.is_a_stripe_connect_account?

    true
  end

  def funding_type
    card[:funding].presence if card.present?
  end

  def fingerprint
    card[:fingerprint].presence if card.present?
  end

  def last4
    card[:last4].presence if card.present?
  end

  def number_length
    ChargeableVisual.get_card_length_from_card_type(card_type) if card_type
  end

  def visual
    ChargeableVisual.build_visual(last4, number_length) if last4.present? && number_length.present?
  end

  def expiry_month
    card[:exp_month].presence if card.present?
  end

  def expiry_year
    card[:exp_year].presence if card.present?
  end

  def zip_code
    return @payment_method.billing_details[:address][:postal_code].presence if @payment_method.present?

    @zip_code
  end

  def card_type
    return StripeCardType.to_new_card_type(card[:brand]) if card.present? && card[:brand].present?

    # Non-card methods (UPI, iDEAL, Link, ...) have no card block, which used to leave
    # purchases.card_type nil and made their volume invisible in payment-method metrics.
    # Record the method's own type instead, but only when it maps to a known CardType —
    # an unrecognized method keeps the historical nil rather than leaking "generic_card".
    method_type = payment_method&.type
    mapped = StripeCardType.to_new_card_type(method_type) if method_type.present?
    mapped unless mapped == CardType::UNKNOWN
  end

  def country
    card[:country].presence if card.present?
  end

  def card
    @merchant_account&.is_a_stripe_connect_account? ? @payment_method_on_connect_account&.card : @payment_method&.card
  end

  # The Stripe::PaymentMethod backing this chargeable (fetched by #prepare!). Mirrors the
  # connect-account selection in #card so both read the same object.
  def payment_method
    @merchant_account&.is_a_stripe_connect_account? ? @payment_method_on_connect_account : @payment_method
  end

  def reusable_token!(user)
    if @customer_id.blank?
      with_stripe_error_handler do
        creation_params = { description: user&.id.to_s, email: user&.email, payment_method: @payment_method_id }

        customer = Stripe::Customer.create(creation_params)

        @customer_id = customer.id
      end
    end

    @customer_id
  end

  def stripe_charge_params
    if @merchant_account&.is_a_stripe_connect_account?
      { payment_method: @payment_method_id_on_connect_account }
    else
      { customer: @customer_id, payment_method: @payment_method_id }
    end
  end

  def requires_mandate?
    country == "IN"
  end

  private
    def get_merchant_account(permalink)
      return unless permalink

      link = Link.find_by unique_permalink: permalink
      link&.user && link.user.merchant_account(StripeChargeProcessor.charge_processor_id)
    end

    # On the front end we always create payment methods linked to our platform account. They must be
    # first cloned to the connected account before attempting a direct charge.
    # https://stripe.com/docs/payments/payment-methods/connect#cloning-payment-methods
    def prepare_for_direct_charge
      return unless @merchant_account&.is_a_stripe_connect_account?

      with_stripe_error_handler do
        @payment_method_on_connect_account = Stripe::PaymentMethod.create({ customer: reusable_token!(nil), payment_method: @payment_method_id },
                                                                          { stripe_account: @merchant_account.charge_processor_merchant_id })

        @payment_method_id_on_connect_account = @payment_method_on_connect_account.id
      end
    end
end
