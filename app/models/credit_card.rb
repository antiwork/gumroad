# frozen_string_literal: true

class CreditCard < ApplicationRecord
  include PurchaseErrorCode
  include ChargeProcessable

  has_many :users
  has_one :purchase
  has_one :subscription

  belongs_to :preorder, optional: true
  has_one :bank_account

  attr_accessor :error_code, :stripe_error_code

  validates :stripe_fingerprint, presence: true
  validates :visual, :card_type, presence: true
  validates :stripe_customer_id, :expiry_month, :expiry_year, presence: true, if: -> { card_type != CardType::PAYPAL }
  validates :braintree_customer_id, presence: { if: :braintree_charge_processor? }
  validates :paypal_billing_agreement_id, presence: { if: :paypal_charge_processor? }
  validates :charge_processor_id, presence: true

  def as_json
    {
      credit: "saved",
      visual: visual.gsub("*", "&middot;").html_safe,
      type: card_type,
      processor: charge_processor_id,
      date: expiry_visual
    }
  end

  def self.new_card_info
    { credit: "new", visual: nil, type: nil, processor: nil, date: nil }
  end

  def self.test_card_info
    { credit: "test", visual: nil, type: nil, processor: nil, date: nil }
  end

  def expiry_visual
    return nil if expiry_month.nil? || expiry_year.nil?

    expiry_month.to_s.rjust(2, "0") + "/" + expiry_year.to_s[-2, 2]
  end

  def self.create(chargeable, card_data_handling_mode = nil, user = nil)
    credit_card = CreditCard.new
    credit_card.card_data_handling_mode = card_data_handling_mode
    credit_card.charge_processor_id = chargeable.charge_processor_id
    begin
      chargeable.prepare!

      credit_card.visual = chargeable.visual
      credit_card.funding_type = chargeable.funding_type

      credit_card.stripe_customer_id = chargeable.reusable_token_for!(StripeChargeProcessor.charge_processor_id, user)
      credit_card.braintree_customer_id = chargeable.reusable_token_for!(BraintreeChargeProcessor.charge_processor_id, user)
      credit_card.paypal_billing_agreement_id = chargeable.reusable_token_for!(PaypalChargeProcessor.charge_processor_id, user)

      credit_card.processor_payment_method_id = chargeable.payment_method_id
      credit_card.stripe_fingerprint = chargeable.fingerprint
      credit_card.card_type = chargeable.card_type
      credit_card.expiry_month = chargeable.expiry_month
      credit_card.expiry_year = chargeable.expiry_year
      credit_card.card_country = chargeable.country

      # Only required for recurring purchases in India via Stripe, which use e-mandates:
      # https://stripe.com/docs/india-recurring-payments?integration=paymentIntents-setupIntents
      if chargeable.requires_mandate?
        credit_card.json_data = { stripe_setup_intent_id: chargeable.try(:stripe_setup_intent_id), stripe_payment_intent_id: chargeable.try(:stripe_payment_intent_id) }
      end

      credit_card.save!
    rescue ChargeProcessorInvalidRequestError, ChargeProcessorUnavailableError => e
      logger.error("Error while persisting card with #{credit_card.charge_processor_id}: #{e.message} - card visual: #{credit_card.visual}")
      credit_card.errors.add(:base, "There is a temporary problem, please try again (your card was not charged).")
      credit_card.error_code = credit_card.charge_processor_unavailable_error
    rescue ChargeProcessorCardError => e
      logger.info("Error while persisting card with #{credit_card.charge_processor_id}: #{e.message} - card visual: #{credit_card.visual}")
      credit_card.errors.add(:base, PurchaseErrorCode.customer_error_message(e.message))
      credit_card.stripe_error_code = e.error_code
    end

    credit_card
  end

  def charge_processor_unavailable_error
    charge_processor_id.blank? || stripe_charge_processor? ?
      PurchaseErrorCode::STRIPE_UNAVAILABLE :
      PurchaseErrorCode::PAYPAL_UNAVAILABLE
  end

  def to_chargeable(merchant_account: nil)
    reusable_tokens = {
      StripeChargeProcessor.charge_processor_id => stripe_customer_id,
      BraintreeChargeProcessor.charge_processor_id => braintree_customer_id,
      PaypalChargeProcessor.charge_processor_id => paypal_billing_agreement_id
    }
    ChargeProcessor.get_chargeable_for_data(
      reusable_tokens,
      processor_payment_method_id,
      stripe_fingerprint,
      stripe_setup_intent_id,
      stripe_payment_intent_id,
      ChargeableVisual.is_cc_visual(visual) ? ChargeableVisual.get_card_last4(visual) : nil,
      visual.gsub(/\s/, "").length,
      visual,
      expiry_month,
      expiry_year,
      card_type,
      card_country,
      merchant_account:
    )
  end

  def last_four_digits
    visual.split.last
  end

  def requires_mandate?
    card_country == "IN"
  end

  def stripe_setup_intent_id
    json_data && json_data.deep_symbolize_keys[:stripe_setup_intent_id]
  end

  def stripe_payment_intent_id
    json_data && json_data.deep_symbolize_keys[:stripe_payment_intent_id]
  end
end
