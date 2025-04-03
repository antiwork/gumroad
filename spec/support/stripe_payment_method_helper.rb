# frozen_string_literal: true

module StripePaymentMethodHelper
  EXPIRY_MM = "12"
  EXPIRY_YYYY = Time.current.strftime("%Y")
  EXPIRY_YY = Time.current.strftime("%y")
  EXPIRY_MMYY = "#{EXPIRY_MM}/#{EXPIRY_YY}"

  module ExtensionMethods
    def to_stripe_card_hash
      expiry_month, expiry_year = CreditCardUtility.extract_month_and_year(self[:expiry_date]) if self[:expiry_date]
      stripe_params = {}
      stripe_params[:number] = self[:cc_number] if self[:cc_number]
      stripe_params[:exp_month] = expiry_month if expiry_month
      stripe_params[:exp_year] = expiry_year if expiry_year
      stripe_params[:cvc] = self[:cvc] if self[:cvc]
      stripe_params
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
      to_stripejs_payment_method.id
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

  def build(number: "4242 4242 4242 4242", expiry_month: EXPIRY_MM, expiry_year: EXPIRY_YYYY, cvc: "123")
    card_params = {
      cc_number: number,
      expiry_date: "#{expiry_month} / #{expiry_year}",
      cvc:
    }
    card_params.extend(StripePaymentMethodHelper::ExtensionMethods)
    card_params
  end

  def success
    build
  end

  def success_with_sca
    build(number: "4000 0025 0000 3155")
  end

  def success_future_usage_set_up
    build(number: "4000 0038 0000 0446")
  end

  # SCA supported, but not required
  def success_sca_not_required
    build(number: "4000000000003055")
  end

  def success_discover
    build(number: "6011 0009 9013 9424")
  end

  def success_debit_visa
    build(number: "4000 0566 5566 5556")
  end

  def success_zip_check_unsupported
    build(number: "4000 0000 0000 0044")
  end

  def success_zip_check_fails
    build(number: "4000 0000 0000 0036")
  end

  def success_charge_decline
    build(number: "4000 0000 0000 0341")
  end

  def decline
    build(number: "4000 0000 0000 0002")
  end

  def decline_expired
    build(number: "4000 0000 0000 0069")
  end

  def decline_invalid_luhn
    build(number: "4242 4242 4242 4241")
  end

  def decline_cvc_check_fails
    build(number: "4000 0000 0000 0101")
  end

  def decline_fraudulent
    build(number: "4100 0000 0000 0019")
  end

  def success_charge_disputed
    build(number: "4000 0000 0000 0259")
  end

  def success_available_balance
    build(number: "4000 0000 0000 0077")
  end

  def success_indian_card_mandate
    build(number: "4000 0035 6000 0123")
  end

  def cancelled_indian_card_mandate
    build(number: "4000 0035 6000 0263")
  end

  def decline_indian_card_mandate
    build(number: "4000 0035 6000 0297")
  end

  def fail_indian_card_mandate
    build(number: "4000 0035 6000 0248")
  end
end
