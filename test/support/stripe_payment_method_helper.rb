# frozen_string_literal: true

module StripePaymentMethodHelper
  EXPIRY_MM = "12"
  EXPIRY_YYYY = Time.current.strftime("%Y")
  EXPIRY_YY = Time.current.strftime("%y")
  EXPIRY_MMYY = "#{EXPIRY_MM}/#{EXPIRY_YY}"

  module ExtensionMethods
    def to_stripe_card_hash
      { token: self[:token] }
    end

    def to_stripe_billing_details
      return if self[:cc_zipcode].blank?

      {
        address: {
          postal_code: self[:cc_zipcode]
        }
      }
    end

    def to_stripejs_payment_method
      @_stripe_payment_method ||= Stripe::PaymentMethod.create(
        type: "card",
        card: to_stripe_card_hash,
        billing_details: to_stripe_billing_details
      )
    end

    def to_stripejs_wallet_payment_method
      payment_method_hash = to_stripejs_payment_method.to_hash
      payment_method_hash[:card][:wallet] = { type: "apple_pay" }
      Stripe::Util.convert_to_stripe_object(payment_method_hash)
    end

    def to_stripejs_payment_method_id
      self[:payment_method_id] || to_stripejs_payment_method.id
    end

    def to_stripejs_customer(prepare_future_payments: false)
      if @_stripe_customer.nil?
        @_stripe_customer = Stripe::Customer.create(payment_method: to_stripejs_payment_method_id)

        if prepare_future_payments
          Stripe::SetupIntent.create(
            payment_method: to_stripejs_payment_method_id,
            customer: @_stripe_customer.id,
            payment_method_types: ["card"],
            confirm: true,
            usage: "off_session"
          )
        end
      end

      @_stripe_customer
    end

    def to_stripejs_customer_id
      to_stripejs_customer.id
    end

    def to_stripejs_fingerprint
      to_stripejs_payment_method.card.fingerprint
    end

    def to_stripejs_params(prepare_future_payments: false)
      begin
        stripejs_params = {
          card_data_handling_mode: CardDataHandlingMode::TOKENIZE_VIA_STRIPEJS,
          stripe_payment_method_id: to_stripejs_payment_method_id
        }.tap do |params|
          params[:stripe_customer_id] = to_stripejs_customer(prepare_future_payments: true).id if prepare_future_payments
        end
      rescue Stripe::InvalidRequestError, Stripe::APIConnectionError, Stripe::APIError, Stripe::CardError => e
        stripejs_params = StripePaymentMethodHelper::StripeJs.build_error(e.json_body[:type], e.json_body[:message], code: e.json_body[:code])
      end
      stripejs_params
    end

    def with_zip_code(zip_code = "12345")
      with(:cc_zipcode, zip_code)
    end

    def with(key, value)
      copy = clone
      copy[key] = value
      copy.extend(ExtensionMethods)
      copy
    end

    def without(key)
      copy = clone
      copy.delete(key)
      copy.extend(ExtensionMethods)
      copy
    end
  end

  class StripeJs
    def self.error_unavailable
      build_error("api_error", "stripe api has gone downnnn")
    end

    def self.build_error(type, message, code: nil)
      {
        card_data_handling_mode: CardDataHandlingMode::TOKENIZE_VIA_STRIPEJS,
        stripe_error: {
          type:,
          message:,
          code:
        }
      }
    end
  end

  module_function

  def build(token: "tok_visa", payment_method_id: nil)
    card_params = payment_method_id.present? ? { payment_method_id: } : { token: }
    card_params.extend(StripePaymentMethodHelper::ExtensionMethods)
    card_params
  end

  def success
    build
  end

  def success_with_sca
    build(token: "tok_threeDSecure2Required")
  end

  def success_future_usage_set_up
    build(payment_method_id: "pm_card_authenticationRequiredSetupForOffSession")
  end

  # SCA supported, but not required
  def success_sca_not_required
    build(token: "tok_threeDSecureOptional")
  end

  def success_discover
    build(token: "tok_discover")
  end

  def success_debit_visa
    build(token: "tok_visa_debit")
  end

  def success_zip_check_unsupported
    build(token: "tok_avsUnchecked")
  end

  def success_zip_check_fails
    build(token: "tok_avsZipFail")
  end

  def success_charge_decline
    build(token: "tok_visa_chargeCustomerFail")
  end

  def decline
    build(token: "tok_visa_chargeDeclined")
  end

  def decline_expired
    build(token: "tok_chargeDeclinedExpiredCard")
  end

  def decline_invalid_luhn
    build(token: "tok_visa_chargeDeclinedProcessingError")
  end

  def decline_cvc_check_fails
    build(token: "tok_cvcCheckFail")
  end

  def decline_fraudulent
    build(token: "tok_radarBlock")
  end

  def success_charge_disputed
    build(token: "tok_createDispute")
  end

  def success_available_balance
    build(token: "tok_bypassPending")
  end

  def success_indian_card_mandate
    build(payment_method_id: "pm_card_indiaRecurringMandateSetupAndRenewalsSuccess")
  end

  def cancelled_indian_card_mandate
    build(payment_method_id: "pm_card_indiaRecurringPaymentFailureCanceledMandate")
  end

  def decline_indian_card_mandate
    build(payment_method_id: "pm_card_indiaRecurringPaymentFailureAfterPreDebitNotification")
  end

  def fail_indian_card_mandate
    build(payment_method_id: "pm_card_indiaRecurringPaymentFailureUndeliveredDebitNotification")
  end
end
