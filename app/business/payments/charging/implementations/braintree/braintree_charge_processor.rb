# frozen_string_literal: true

class BraintreeChargeProcessor
  DISPLAY_NAME = "Braintree"

  MAXIMUM_DESCRIPTOR_LENGTH = 18

  PROCESSOR_UNSUPPORTED_PAYMENT_ACCOUNT_ERROR_CODE = "2071"

  PROCESSOR_UNSUPPORTED_PAYMENT_INSTRUMENT_ERROR_CODE = "2074"

  private_constant :MAXIMUM_DESCRIPTOR_LENGTH, :PROCESSOR_UNSUPPORTED_PAYMENT_ACCOUNT_ERROR_CODE, :PROCESSOR_UNSUPPORTED_PAYMENT_INSTRUMENT_ERROR_CODE

  # https://developers.braintreepayments.com/reference/general/statuses#transaction
  VALID_TRANSACTION_STATUSES = [Braintree::Transaction::Status::Settled, Braintree::Transaction::Status::Settling, Braintree::Transaction::Status::SettlementPending].freeze

  def self.charge_processor_id
    "braintree"
  end

  def get_chargeable_for_params(params, _gumroad_guid)
    zip_code = params[:cc_zipcode] if params[:cc_zipcode_required]
    nonce = params[:braintree_nonce]
    transient_customer_token = params[:braintree_transient_customer_store_key]

    braintree_chargeable = BraintreeChargeableNonce.new(nonce, zip_code) if nonce.present?
    if transient_customer_token.present?
      braintree_chargeable ||=
        BraintreeChargeableTransientCustomer.from_transient_customer_store_key(transient_customer_token)
    end

    braintree_chargeable&.braintree_device_data = params[:braintree_device_data]

    braintree_chargeable
  end

  def get_chargeable_for_data(reusable_token, _payment_method_id, fingerprint,
                              _stripe_setup_intent_id, _stripe_payment_intent_id,
                              last4, number_length, visual, expiry_month, expiry_year,
                              card_type, country, zip_code = nil, merchant_account: nil)
    BraintreeChargeableCreditCard.new(reusable_token, fingerprint, last4, number_length, visual, expiry_month, expiry_year, card_type, country, zip_code)
  end

  def search_charge(purchase:)
    matched_transactions = Braintree::Transaction.search do |search|
      search.order_id.is purchase.external_id
    end
    matched_transactions.first
  end

  def get_charge(charge_id, **_args)
    begin
      braintree_transaction = Braintree::Transaction.find(charge_id)
    rescue Braintree::ValidationsFailed, Braintree::ServerError, Braintree::NotFoundError => e
      raise ChargeProcessorInvalidRequestError.new(original_error: e)
    rescue *BraintreeExceptions::UNAVAILABLE => e
      raise ChargeProcessorUnavailableError.new(original_error: e)
    end
    get_charge_object(braintree_transaction)
  end

  def get_charge_object(charge)
    BraintreeCharge.new(charge, load_extra_details: true)
  end

  def create_payment_intent_or_charge!(merchant_account, chargeable, amount_cents, _amount_for_gumroad_cents, reference,
                                       description, metadata: nil,
                                       statement_description: nil, **_args)
    params = {
      merchant_account_id: merchant_account.charge_processor_merchant_id,
      amount: amount_cents / 100.0,
      customer_id: chargeable.braintree_customer_id,
      order_id: reference, # PayPal Invoice ID
      device_data: chargeable.braintree_device_data,
      options: {
        submit_for_settlement: true,
        paypal: {
          description:
        }
      },
      custom_fields: {
        purchase_external_id: reference,
        description:
      },
      channel: "GUMROAD_SP"
    }

    if statement_description
      statement_description = statement_description.gsub(/[^A-Z0-9. ]/i, "").to_s.strip[0...MAXIMUM_DESCRIPTOR_LENGTH]
      # This is not an ideal solution, as the resulting descriptor name will be "GUM*GUM.CO/CC Creator "
      # It is this way because Braintree requires:
      # Company name/DBA section must be either 3, 7 or 12 characters and the product descriptor can be up to 18, 14, or 9 characters
      # respectively (with an * in between for a total descriptor name of 22 characters).
      if statement_description.present?
        params[:descriptor] = {
          name: "GUM*#{statement_description}",
          phone: GUMROAD_MERCHANT_DESCRIPTOR_PHONE_NUMBER,
          url: GUMROAD_MERCHANT_DESCRIPTOR_URL
        }
      end
    end

    begin
      braintree_charge = Braintree::Transaction.sale(params)
      transaction = braintree_charge.transaction

      unless transaction.try(:status).in?(VALID_TRANSACTION_STATUSES)
        if braintree_charge.errors.any?
          # Expected to contain Braintree::ValidationsFailed
          error = braintree_charge.errors.first
          raise ChargeProcessorCardError.new(error.code,
                                             error.message,
                                             charge_id: transaction.try(:id))
        end

        raise ChargeProcessorCardError, Braintree::Transaction::Status::Failed if transaction.nil?

        if transaction.status == Braintree::Transaction::Status::GatewayRejected
          raise ChargeProcessorCardError.new(Braintree::Transaction::Status::GatewayRejected,
                                             transaction.gateway_rejection_reason,
                                             charge_id: transaction.try(:id))
        elsif transaction.status == Braintree::Transaction::Status::ProcessorDeclined
          if transaction.processor_response_code == PROCESSOR_UNSUPPORTED_PAYMENT_ACCOUNT_ERROR_CODE
            raise ChargeProcessorUnsupportedPaymentAccountError.new(transaction.processor_response_code,
                                                                    transaction.processor_response_text,
                                                                    charge_id: transaction.id)
          elsif transaction.processor_response_code == PROCESSOR_UNSUPPORTED_PAYMENT_INSTRUMENT_ERROR_CODE
            raise ChargeProcessorUnsupportedPaymentTypeError.new(transaction.processor_response_code,
                                                                 transaction.processor_response_text,
                                                                 charge_id: transaction.id)
          end
          raise ChargeProcessorCardError.new(transaction.processor_response_code,
                                             transaction.processor_response_text,
                                             charge_id: transaction.id)
        elsif transaction.status == Braintree::Transaction::Status::SettlementDeclined
          raise ChargeProcessorCardError.new(transaction.processor_settlement_response_code,
                                             transaction.processor_settlement_response_text,
                                             charge_id: transaction.id)
        else
          raise ChargeProcessorCardError.new(Braintree::Transaction::Status::Failed,
                                             charge_id: transaction.id)
        end
      end
    rescue Braintree::ServerError => e
      raise ChargeProcessorInvalidRequestError.new(original_error: e)
    rescue *BraintreeExceptions::UNAVAILABLE => e
      raise ChargeProcessorUnavailableError.new(original_error: e)
    rescue Braintree::BraintreeError => e
      raise ChargeProcessorInvalidRequestError.new(original_error: e)
    end

    charge = BraintreeCharge.new(transaction, load_extra_details: false)
    BraintreeChargeIntent.new(charge:)
  end

  def refund!(charge_id, amount_cents: nil, **_args)
    begin
      braintree_transaction =
        if amount_cents.nil?
          Braintree::Transaction.refund!(charge_id)
        else
          Braintree::Transaction.refund!(charge_id, amount_cents / 100.0)
        end
    rescue Braintree::ValidationsFailed => e
      first_error = e.error_result.errors.first
      if first_error.try(:code) == Braintree::ErrorCodes::Transaction::HasAlreadyBeenRefunded
        raise ChargeProcessorAlreadyRefundedError.new("Braintree charge was already refunded. Braintree response: #{first_error.message}", original_error: e)
      end

      raise ChargeProcessorInvalidRequestError.new(original_error: e)
    rescue Braintree::ServerError => e
      raise ChargeProcessorInvalidRequestError.new(original_error: e)
    rescue *BraintreeExceptions::UNAVAILABLE => e
      raise ChargeProcessorUnavailableError.new(original_error: e)
    rescue Braintree::BraintreeError => e
      raise ChargeProcessorInvalidRequestError.new(original_error: e)
    end

    BraintreeChargeRefund.new(braintree_transaction)
  end

  def holder_of_funds(_merchant_account)
    HolderOfFunds::GUMROAD
  end

  def transaction_url(charge_id)
    sub_domain = Rails.env.production? ? "www" : "sandbox"
    "https://#{sub_domain}.braintreegateway.com/merchants/#{Braintree::Configuration.merchant_id}/transactions/#{charge_id}"
  end
end
