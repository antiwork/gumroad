# frozen_string_literal: true

class PurchasePaymentFlow < ApplicationRecord
  belongs_to :purchase

  # Durable, persisted analytics values. They are owned here and deliberately kept independent of
  # the checkout integration strings in Checkout::StripePaymentPresenter, which can change without
  # rewriting historical rows.
  CARD_ELEMENT = "card_element"
  PAYMENT_ELEMENT = "payment_element"
  PAYMENT_REQUEST = "payment_request"
  SAVED_PAYMENT_METHOD = "saved_payment_method"

  PAYMENT_METHOD = "payment_method"

  CARD = "card"

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
end
