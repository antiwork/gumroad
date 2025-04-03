# frozen_string_literal: true

class PaypalApprovedOrderChargeable
  attr_reader :fingerprint, :last4, :number_length, :visual, :expiry_month,
              :expiry_year, :zip_code, :card_type, :country, :funding_type, :email

  def initialize(order_id, visual, country)
    @fingerprint = order_id
    @visual = visual
    @email = visual
    @card_type = CardType::PAYPAL
    @country = country
  end

  def charge_processor_id
    PaypalChargeProcessor.charge_processor_id
  end

  def prepare!
    true
  end

  def reusable_token!(_user_id)
    nil
  end
end
