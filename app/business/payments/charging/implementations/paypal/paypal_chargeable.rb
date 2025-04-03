# frozen_string_literal: true

class PaypalChargeable
  attr_reader :billing_agreement_id, :fingerprint, :last4, :number_length, :visual, :expiry_month,
              :expiry_year, :zip_code, :card_type, :country, :funding_type, :email, :payment_method_id

  def initialize(billing_agreement_id, visual, country)
    @billing_agreement_id = billing_agreement_id
    @fingerprint = billing_agreement_id
    @visual = visual
    @email = visual
    @card_type = CardType::PAYPAL
    @country = country
  end

  def charge_processor_id
    PaypalChargeProcessor.charge_processor_id
  end

  def prepare!
    billing_agreement_id.present?
  end

  def reusable_token!(_user)
    billing_agreement_id
  end
end
