# frozen_string_literal: true

# Public: Chargeable representing a card stored at Stripe.
class StripeChargeableCreditCard
  include StripeErrorHandler

  attr_accessor :validated_stripe_mandate_id

  attr_reader :fingerprint, :payment_method_id, :last4, :visual, :number_length,
              :expiry_month, :expiry_year, :zip_code, :card_type, :country,
              :stripe_payment_intent_id
  attr_accessor :stripe_setup_intent_id

  def initialize(merchant_account, reusable_token, payment_method_id, fingerprint,
                 stripe_setup_intent_id, stripe_payment_intent_id,
                 last4, number_length, visual, expiry_month, expiry_year, card_type,
                 country, zip_code = nil)
    @merchant_account = merchant_account
    @customer_id = reusable_token
    @payment_method_id = payment_method_id
    @fingerprint = fingerprint
    @stripe_setup_intent_id = stripe_setup_intent_id
    @stripe_payment_intent_id = stripe_payment_intent_id
    @last4 = last4
    @number_length = number_length
    @visual = visual
    @expiry_month = expiry_month
    @expiry_year = expiry_year
    @card_type = card_type
    @country = country
    @zip_code = zip_code
  end

  def funding_type
    nil
  end

  def charge_processor_id
    StripeChargeProcessor.charge_processor_id
  end

  def prepare!
    @payment_method_id ||= Stripe::Customer.retrieve(@customer_id).default_source ||
      Stripe::PaymentMethod.list({ customer: @customer_id, type: "card" }).data[0].id

    if @merchant_account&.is_a_stripe_connect_account?
      # Renewals and other saved-card charges call prepare! without the order-service binder.
      # When this chargeable already carries a Connect SetupIntent, reuse that mandate's PM
      # instead of cloning a mandate-less copy.
      if bind_connected_setup_intent_payment_method!
        true
      else
        prepare_for_direct_charge
        update_card_details
        true
      end
    else
      true
    end
  end

  def reusable_token!(_user)
    @customer_id
  end

  def stripe_charge_params
    if @merchant_account&.is_a_stripe_connect_account?
      params = { payment_method: @payment_method_id_on_connect_account }
      params[:customer] = @customer_id_on_connect_account if @customer_id_on_connect_account.present?
      params
    else
      { customer: @customer_id, payment_method: @payment_method_id }
    end
  end

  def requires_mandate?
    country == "IN"
  end

  # We always save the payment methods linked to our platform account. They must be
  # first cloned to the connected account before attempting a direct charge.
  # https://stripe.com/docs/payments/payment-methods/connect#cloning-payment-methods
  def prepare_for_direct_charge
    return unless @merchant_account&.is_a_stripe_connect_account?

    with_stripe_error_handler do
      # Old credit card records do not have a payment method ID on record, only the customer ID.
      # In such cases, we fetch the payment method associated with the customer first and then clone it.
      @payment_method_id = Stripe::PaymentMethod.list({ customer: @customer_id, type: "card" }).data[0].id if @payment_method_id.blank?

      @payment_method_on_connect_account = Stripe::PaymentMethod.create({ customer: @customer_id, payment_method: @payment_method_id },
                                                                        { stripe_account: @merchant_account.charge_processor_merchant_id })

      @payment_method_id_on_connect_account = @payment_method_on_connect_account.id
    end
  end

  # Charge with a payment method that already lives on the connected account — e.g. the clone a
  # confirmed SetupIntent registered its e-mandate on. Stripe binds mandates to the exact payment
  # method, so cloning again via #prepare_for_direct_charge would drop the mandate.
  def use_connected_account_payment_method!(payment_method_id)
    @payment_method_id_on_connect_account = payment_method_id
  end

  def bind_connected_setup_intent_payment_method!
    return false if @stripe_setup_intent_id.blank? || !@merchant_account&.is_a_stripe_connect_account?

    begin
      with_stripe_error_handler do
        setup_intent = Stripe::SetupIntent.retrieve(
          @stripe_setup_intent_id,
          { stripe_account: @merchant_account.charge_processor_merchant_id }
        )
        payment_method_id = setup_intent.payment_method
        payment_method_id = payment_method_id.id if payment_method_id.respond_to?(:id)
        return false if payment_method_id.blank?

        stripe_account = { stripe_account: @merchant_account.charge_processor_merchant_id }
        payment_method = Stripe::PaymentMethod.retrieve(payment_method_id, stripe_account)
        # Unattached Connect clones are consumed by the first charge. Attach to a Customer on
        # this connected account so renewals can reuse the mandate's payment method.
        if payment_method.customer.blank?
          customer = Stripe::Customer.create({}, stripe_account)
          payment_method = Stripe::PaymentMethod.attach(payment_method_id, { customer: customer.id }, stripe_account)
        end
        customer_id = payment_method.customer
        customer_id = customer_id.id if customer_id.respond_to?(:id)
        @customer_id_on_connect_account = customer_id

        use_connected_account_payment_method!(payment_method_id)
        @payment_method_on_connect_account = payment_method
        update_card_details
        true
      end
    rescue ChargeProcessorInvalidRequestError
      # Legacy scalar SI IDs may belong to another Stripe account; fall through to a fresh clone.
      false
    end
  end

  def update_card_details
    card = @payment_method_on_connect_account&.card
    return unless card.present?

    @fingerprint = card[:fingerprint].presence
    @last4 = card[:last4].presence
    @card_type = StripeCardType.to_new_card_type(card[:brand]) if card[:brand].present?
    @number_length = ChargeableVisual.get_card_length_from_card_type(card_type)
    @visual = ChargeableVisual.build_visual(last4, number_length) if last4.present? && number_length.present?
    @expiry_month = card[:exp_month].presence
    @expiry_year = card[:exp_year].presence
    @country = card[:country].presence
    @zip_code = @payment_method_on_connect_account.billing_details[:address][:postal_code].presence || zip_code
  end
end
