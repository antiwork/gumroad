# frozen_string_literal: true

class BraintreeChargeableBase
  attr_accessor :braintree_device_data
  attr_reader :payment_method_id

  def charge_processor_id
    BraintreeChargeProcessor.charge_processor_id
  end

  def prepare!
    raise NotImplementedError
  end

  def funding_type
    nil
  end

  def fingerprint
    return @card.unique_number_identifier if @card
    return PaypalCardFingerprint.build_paypal_fingerprint(@paypal.email) if @paypal

    nil
  end

  def last4
    return @card.last_4 if @card

    nil
  end

  def visual
    return ChargeableVisual.build_visual(last4, number_length) if last4.present? && number_length.present?
    return @paypal.email if @paypal

    nil
  end

  def number_length
    return ChargeableVisual.get_card_length_from_card_type(card_type) if @card && card_type

    nil
  end

  def expiry_month
    @card.try(:expiration_month)
  end

  def expiry_year
    @card.try(:expiration_year)
  end

  def zip_code
    return @card.billing_address.postal_code if @card&.billing_address

    @zip_code
  end

  def card_type
    return BraintreeCardType.to_card_type(@card.card_type) if @card
    return CardType::PAYPAL if @paypal

    nil
  end

  def country
    BraintreeChargeCountry.to_card_country(@card.country_of_issuance) if @card
  end

  def reusable_token!(user)
    prepare!
    @customer = Braintree::Customer.update!(@customer.id, company: user.id) if user && user.id != @customer.company
    @customer.id
  rescue Braintree::ValidationsFailed, Braintree::ServerError => e
    raise ChargeProcessorInvalidRequestError.new(original_error: e)
  rescue *BraintreeExceptions::UNAVAILABLE => e
    raise ChargeProcessorUnavailableError.new(original_error: e)
  end

  def braintree_customer_id
    prepare!
    @customer.id
  end
end
