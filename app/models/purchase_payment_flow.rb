# frozen_string_literal: true

class PurchasePaymentFlow < ApplicationRecord
  belongs_to :purchase

  CARD_ELEMENT = "card_element"
  PAYMENT_ELEMENT = "payment_element"
  PAYMENT_REQUEST = "payment_request"
  SAVED_PAYMENT_METHOD = "saved_payment_method"

  PAYMENT_METHOD = "payment_method"

  CARD = "card"

  STRIPE_PAYMENT_PARAM_KEYS = %i[stripe_payment_method_id stripe_setup_intent_id stripe_error].freeze
  NON_STRIPE_PAYMENT_PARAM_KEYS = %i[paypal_order_id billing_agreement_id braintree_transient_customer_store_key braintree_device_data].freeze

  enum :payment_details_source, {
    card_element: CARD_ELEMENT,
    payment_element: PAYMENT_ELEMENT,
    payment_request: PAYMENT_REQUEST,
    saved_payment_method: SAVED_PAYMENT_METHOD,
  }, prefix: true, validate: true

  enum :payment_details_transport, { payment_method: PAYMENT_METHOD }, prefix: true, validate: true

  validates :stripe_payment_method_type, presence: true

  def self.attributes_for_checkout_params(params)
    source = payment_details_source_for(params)
    return if source.nil?
    return unless stripe_payment_submission?(source, params)

    {
      payment_details_source: source,
      payment_details_transport: PAYMENT_METHOD,
      stripe_payment_method_type: CARD,
    }
  end

  def self.payment_details_source_for(params)
    return PAYMENT_REQUEST if params[:wallet_type].present?

    source = params[:payment_details_source].presence
    source if payment_details_sources.value?(source)
  end
  private_class_method :payment_details_source_for

  def self.stripe_payment_submission?(source, params)
    return false if NON_STRIPE_PAYMENT_PARAM_KEYS.any? { params[_1].present? }
    return params[:stripe_payment_method_id].blank? if source == SAVED_PAYMENT_METHOD

    STRIPE_PAYMENT_PARAM_KEYS.any? { params[_1].present? }
  end
  private_class_method :stripe_payment_submission?
end
