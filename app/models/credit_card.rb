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
  validates :stripe_customer_id, presence: true, if: -> { card_type != CardType::PAYPAL }
  validates :expiry_month, :expiry_year, presence: true, if: -> { card_type != CardType::PAYPAL && !upi? }
  validates :processor_payment_method_id, :recurring_authorization_verified_at,
            :recurring_authorization_currency, :recurring_authorization_max_amount_cents,
            presence: true, if: :recurring_upi?
  validates :recurring_authorization_currency, inclusion: { in: [Currency::INR] }, if: :recurring_upi?
  validates :recurring_authorization_max_amount_cents,
            numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: Checkout::PaymentMethodResolver::UPI_RECURRING_MAX_INR_CENTS },
            if: :recurring_upi?
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
    rescue ChargeProcessorInvalidRequestError => e
      # The processor rejected our request as malformed — a deterministic failure on our side,
      # not an outage. Record it under its own code so a code regression shows up in monitoring
      # instead of hiding inside Stripe-outage noise. Retry behavior is unchanged.
      logger.error("Error while persisting card with #{credit_card.charge_processor_id}: #{e.message} - card visual: #{credit_card.visual}")
      credit_card.errors.add(:base, "There is a temporary problem, please try again (your card was not charged).")
      credit_card.error_code = PurchaseErrorCode::PROCESSOR_INVALID_REQUEST
      credit_card.stripe_error_code = e.processor_error_code if credit_card.stripe_error_code.blank?
    rescue ChargeProcessorUnavailableError => e
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

  # Persists a recurring method only after Stripe proves a successful off-session setup.
  # UPI has no exposed Mandate id, so its durable contract is Customer + PaymentMethod + account.
  def self.create_from_client_confirmed_intent!(payment_intent:, processor_charge:, merchant_account:)
    payment_method_type = processor_charge.payment_method_type.to_s
    unless payment_method_type.in?(%w[card upi])
      raise ArgumentError, "Cannot save #{payment_method_type.presence || 'unknown'} as a recurring checkout payment method"
    end
    unless payment_intent[:setup_future_usage] == "off_session"
      raise ArgumentError, "PaymentIntent #{payment_intent.id} did not verify off-session reuse"
    end
    unless payment_intent[:status] == StripeIntentStatus::SUCCESS
      raise ArgumentError, "PaymentIntent #{payment_intent.id} did not succeed"
    end

    customer_id = StripeChargeableUpi.stripe_object_id(payment_intent[:customer])
    payment_method_id = StripeChargeableUpi.stripe_object_id(payment_intent[:payment_method]) || processor_charge.card_instance_id
    raise ArgumentError, "PaymentIntent #{payment_intent.id} has no customer" if customer_id.blank?
    raise ArgumentError, "PaymentIntent #{payment_intent.id} has no payment method" if payment_method_id.blank?

    upi = payment_method_type == Checkout::PaymentMethodResolver::UPI_PAYMENT_METHOD_TYPE
    if upi && payment_intent[:currency].to_s.downcase != Currency::INR
      raise ArgumentError, "PaymentIntent #{payment_intent.id} did not use INR for UPI recurring authorization"
    end
    maximum_amount_cents = if upi
      metadata_value = payment_intent[:metadata]&.[](StripeChargeProcessor::UPI_RECURRING_MAX_AMOUNT_METADATA_KEY.to_sym)
      Integer(metadata_value, exception: false)
    end
    if upi && !(1..Checkout::PaymentMethodResolver::UPI_RECURRING_MAX_INR_CENTS).cover?(maximum_amount_cents)
      raise ArgumentError, "PaymentIntent #{payment_intent.id} did not preserve a valid maximum UPI debit"
    end

    create!(
      charge_processor_id: StripeChargeProcessor.charge_processor_id,
      payment_method_type:,
      stripe_customer_id: customer_id,
      processor_payment_method_id: payment_method_id,
      stripe_fingerprint: processor_charge.card_fingerprint.presence || payment_method_id,
      visual: upi ? "UPI" : ChargeableVisual.build_visual(processor_charge.card_last4, processor_charge.card_number_length),
      card_type: upi ? CardType::UPI : processor_charge.card_type,
      card_country: upi ? Compliance::Countries::IND.alpha2 : processor_charge.card_country,
      funding_type: nil,
      expiry_month: upi ? nil : processor_charge.card_expiry_month,
      expiry_year: upi ? nil : processor_charge.card_expiry_year,
      stripe_account_id: StripeIntentChargeRouting.direct_charge_account?(merchant_account) ? merchant_account.charge_processor_merchant_id : nil,
      recurring_authorization_verified_at: Time.current,
      recurring_authorization_currency: (payment_intent[:currency].to_s.downcase if upi),
      recurring_authorization_max_amount_cents: (maximum_amount_cents if upi),
      json_data: { stripe_payment_intent_id: payment_intent.id }
    )
  end

  def charge_processor_unavailable_error
    charge_processor_id.blank? || stripe_charge_processor? ?
      PurchaseErrorCode::STRIPE_UNAVAILABLE :
      PurchaseErrorCode::PAYPAL_UNAVAILABLE
  end

  def to_chargeable(merchant_account: nil)
    if recurring_upi?
      upi_chargeable = StripeChargeableUpi.new(
        merchant_account:,
        customer_id: stripe_customer_id,
        payment_method_id: processor_payment_method_id,
        fingerprint: stripe_fingerprint,
        stripe_payment_intent_id:,
        stripe_account_id:,
        recurring_authorization_verified_at:,
        recurring_authorization_currency:,
        recurring_authorization_max_amount_cents:
      )
      return Chargeable.new([upi_chargeable])
    end

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
    !upi? && card_country == "IN"
  end

  def upi?
    recurring_upi? || card_type == CardType::UPI
  end

  def recurring_upi?
    payment_method_type == Checkout::PaymentMethodResolver::UPI_PAYMENT_METHOD_TYPE
  end

  def stripe_setup_intent_id
    json_data && json_data.deep_symbolize_keys[:stripe_setup_intent_id]
  end

  def stripe_payment_intent_id
    json_data && json_data.deep_symbolize_keys[:stripe_payment_intent_id]
  end
end
