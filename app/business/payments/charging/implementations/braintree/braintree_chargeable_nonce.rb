# frozen_string_literal: true

class BraintreeChargeableNonce < BraintreeChargeableBase
  def initialize(nonce, zip_code)
    @nonce = nonce
    @zip_code = zip_code
  end

  def prepare!
    unless @paypal || @card
      @customer = Braintree::Customer.create!(
        credit_card: {
          payment_method_nonce: @nonce
        }
      )
      @paypal = @customer.paypal_accounts.first
      @card = @customer.credit_cards.first
    end
    @paypal.present? || @card.present?
  rescue Braintree::ValidationsFailed, Braintree::ServerError => e
    raise ChargeProcessorInvalidRequestError.new(original_error: e)
  rescue *BraintreeExceptions::UNAVAILABLE => e
    raise ChargeProcessorUnavailableError.new(original_error: e)
  end
end
