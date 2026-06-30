# frozen_string_literal: true

class PurchasePaymentFlow < ApplicationRecord
  belongs_to :purchase, optional: true

  CARD_ELEMENT = "card_element"
  PAYMENT_ELEMENT = "payment_element"
  PAYMENT_REQUEST = "payment_request"
  SAVED_PAYMENT_METHOD = "saved_payment_method"
  PAYMENT_DETAILS_SOURCES = [CARD_ELEMENT, PAYMENT_ELEMENT, PAYMENT_REQUEST, SAVED_PAYMENT_METHOD].freeze

  PAYMENT_METHOD = "payment_method"
  CONFIRMATION_TOKEN = "confirmation_token"
  PAYMENT_DETAILS_TRANSPORTS = [PAYMENT_METHOD, CONFIRMATION_TOKEN].freeze

  CARD = "card"

  validates :payment_details_source, inclusion: { in: PAYMENT_DETAILS_SOURCES }
  validates :payment_details_transport, inclusion: { in: PAYMENT_DETAILS_TRANSPORTS }
  validates :stripe_payment_method_type, presence: true

  def self.attributes_for_checkout_params(params)
    source = payment_details_source_for(params)
    return if source.nil?

    {
      payment_details_source: source,
      payment_details_transport: payment_details_transport_for(params),
      stripe_payment_method_type: CARD,
    }
  end

  def self.payment_details_source_for(params)
    return PAYMENT_REQUEST if params[:wallet_type].present?

    source = params[:payment_details_source].presence
    source if PAYMENT_DETAILS_SOURCES.include?(source)
  end
  private_class_method :payment_details_source_for

  def self.payment_details_transport_for(params)
    params[:stripe_confirmation_token_id].present? ? CONFIRMATION_TOKEN : PAYMENT_METHOD
  end
  private_class_method :payment_details_transport_for
end
