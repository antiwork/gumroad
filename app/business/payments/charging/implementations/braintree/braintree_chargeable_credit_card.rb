# frozen_string_literal: true

# Public: Chargeable representing a card stored at Braintree.
class BraintreeChargeableCreditCard
  attr_reader :fingerprint, :last4, :number_length, :visual, :expiry_month, :expiry_year, :zip_code, :card_type, :country
  attr_reader :braintree_customer_id

  def initialize(reusable_token, fingerprint, last4, number_length, visual, expiry_month, expiry_year, card_type, country, zip_code = nil)
    @braintree_customer_id = reusable_token
    @fingerprint = fingerprint
    @last4 = last4
    @number_length = number_length
    @visual = visual
    @expiry_month = expiry_month
    @expiry_year = expiry_year
    @card_type = card_type
    @country = country
    @zip_code = zip_code
  end

  def charge_processor_id
    BraintreeChargeProcessor.charge_processor_id
  end

  def prepare!
    true
  end

  def reusable_token!(_user)
    braintree_customer_id
  end

  def braintree_device_data
    nil
  end
end
