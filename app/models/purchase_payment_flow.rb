# frozen_string_literal: true

class PurchasePaymentFlow < ApplicationRecord
  belongs_to :purchase

  CARD_ELEMENT = "card_element"
  PAYMENT_ELEMENT = "payment_element"
  PAYMENT_REQUEST = "payment_request"
  SAVED_PAYMENT_METHOD = "saved_payment_method"

  PAYMENT_METHOD = "payment_method"
  CONFIRMATION_TOKEN = "confirmation_token"

  CARD = "card"

  STRIPE_PAYMENT_PARAM_KEYS = %i[stripe_payment_method_id stripe_setup_intent_id stripe_error].freeze
  NON_STRIPE_PAYMENT_PARAM_KEYS = %i[paypal_order_id billing_agreement_id braintree_transient_customer_store_key braintree_device_data].freeze

  enum :payment_details_source, {
    card_element: CARD_ELEMENT,
    payment_element: PAYMENT_ELEMENT,
    payment_request: PAYMENT_REQUEST,
    saved_payment_method: SAVED_PAYMENT_METHOD,
  }, prefix: true, validate: true

  # The transport distinguishes the two checkout lanes, which is what rollout monitoring compares:
  # the existing server-confirmed lane submits a PaymentMethod id (`payment_method`), while the
  # client-confirmed Intent lane submits a ConfirmationToken (`confirmation_token`). The source
  # alone cannot tell them apart — both lanes report `payment_element` when the buyer uses the
  # Payment Element.
  enum :payment_details_transport, { payment_method: PAYMENT_METHOD, confirmation_token: CONFIRMATION_TOKEN }, prefix: true, validate: true

  validates :stripe_payment_method_type, presence: true

  def self.attributes_for_checkout_params(params)
    source = payment_details_source_for(params)
    return if source.nil?

    transport = payment_details_transport_for(source, params)
    return if transport.nil?

    {
      payment_details_source: source,
      payment_details_transport: transport,
      stripe_payment_method_type: CARD,
    }
  end

  def self.payment_details_source_for(params)
    if params[:wallet_type].present?
      # A wallet (Apple Pay / Google Pay) paid. Two client surfaces submit wallet payments and
      # they are told apart by the params that accompany wallet_type: the Payment Element lanes
      # send payment_details_source: "payment_element" (with a PaymentMethod id on the
      # server-confirm lane or a confirmation_token on the client-confirm lane), while the
      # Payment Request Button never sends the "payment_element" hint. Anything else claiming a
      # wallet — including a missing or forged hint — is recorded as a payment_request, the only
      # other surface that can produce a wallet payment.
      return params[:payment_details_source] == PAYMENT_ELEMENT ? PAYMENT_ELEMENT : PAYMENT_REQUEST
    end

    source = params[:payment_details_source].presence
    source if payment_details_sources.value?(source)
  end
  private_class_method :payment_details_source_for

  # Derived from which payment params the server actually received, never from a client-supplied
  # label. The `confirmation_token` param only exists on the client-confirm prepare endpoint
  # (OrdersController#prepare threads it through; the server-confirm create endpoint never permits
  # it), so its presence is a reliable lane signal.
  def self.payment_details_transport_for(source, params)
    return if NON_STRIPE_PAYMENT_PARAM_KEYS.any? { params[_1].present? }
    # A saved card sends no new payment details, so any submitted new-payment param (a PaymentMethod
    # id or a ConfirmationToken) contradicts the claimed source and nothing is recorded. This guard
    # must run before the confirmation_token branch below, or a saved-card request carrying a token
    # would be misclassified as a client-confirm purchase.
    return params[:stripe_payment_method_id].blank? && params[:confirmation_token].blank? ? PAYMENT_METHOD : nil if source == SAVED_PAYMENT_METHOD
    return CONFIRMATION_TOKEN if params[:confirmation_token].present?

    PAYMENT_METHOD if STRIPE_PAYMENT_PARAM_KEYS.any? { params[_1].present? }
  end
  private_class_method :payment_details_transport_for
end
