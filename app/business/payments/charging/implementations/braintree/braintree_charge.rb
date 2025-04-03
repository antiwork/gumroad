# frozen_string_literal: true

class BraintreeCharge < BaseProcessorCharge
  def initialize(braintree_charge, load_extra_details:)
    self.charge_processor_id = BraintreeChargeProcessor.charge_processor_id
    self.zip_check_result = nil
    self.id = braintree_charge.id
    self.status = braintree_charge.status.to_s.downcase
    self.refunded = braintree_charge.try(:refunded?)
    self.fee = nil

    currency = Currency::USD
    amount_cents = (braintree_charge.amount * 100).to_i
    self.flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(currency, amount_cents)

    load_details_from_paypal(braintree_charge) if load_extra_details

    return unless braintree_charge.credit_card_details

    load_card_details(braintree_charge.credit_card_details)
    load_extra_card_details(braintree_charge.credit_card_details) if load_extra_details
  end

  private
    def load_card_details(braintree_credit_card)
      self.card_instance_id = braintree_credit_card.token
      self.card_last4 = braintree_credit_card.last_4 if braintree_credit_card.last_4.present?
      self.card_type = BraintreeCardType.to_card_type(braintree_credit_card.card_type)
      self.card_number_length = ChargeableVisual.get_card_length_from_card_type(card_type) if braintree_credit_card.card_type.present?
      self.card_expiry_month = braintree_credit_card.expiration_month if braintree_credit_card.expiration_month.present?
      self.card_expiry_year = braintree_credit_card.expiration_year if braintree_credit_card.expiration_year.present?
      self.card_country = Compliance::Countries.find_by_name(braintree_credit_card.country_of_issuance)&.alpha2 if braintree_credit_card.country_of_issuance.present?
    end

    def load_extra_card_details(braintree_credit_card)
      braintree_payment_method = Braintree::PaymentMethod.find(braintree_credit_card.token)
      if braintree_payment_method.is_a?(Braintree::CreditCard)
        self.card_fingerprint = braintree_payment_method.unique_number_identifier
        self.card_zip_code = braintree_payment_method.billing_address.postal_code if braintree_payment_method.billing_address
      elsif braintree_payment_method.is_a?(Braintree::PayPalAccount)
        self.card_fingerprint = PaypalCardFingerprint.build_paypal_fingerprint(braintree_payment_method.email)
      end
    rescue Braintree::ValidationsFailed, Braintree::ServerError, Braintree::NotFoundError => e
      raise ChargeProcessorInvalidRequestError.new(original_error: e)
    rescue *BraintreeExceptions::UNAVAILABLE => e
      raise ChargeProcessorUnavailableError.new(original_error: e)
    end

    def load_details_from_paypal(braintree_charge)
      paypal_txn_details = PayPal::SDK::Merchant::API.new.get_transaction_details(
        PayPal::SDK::Merchant::API.new.build_get_transaction_details(
          TransactionID: braintree_charge.paypal_details.capture_id))
      self.disputed = paypal_txn_details.PaymentTransactionDetails.PaymentInfo.PaymentStatus.to_s.downcase == PaypalApiPaymentStatus::REVERSED.downcase
    end
end
