# frozen_string_literal: true

module Purchase::Paypal
  extend ActiveSupport::Concern

  included do
    scope :paypal, -> { where(charge_processor_id: PaypalChargeProcessor.charge_processor_id) }
    scope :paypal_orders, -> { where.not(paypal_order_id: nil) }
    scope :unsuccessful_paypal_orders, lambda { |created_after_timestamp, created_before_timestamp|
      not_successful.paypal_orders.created_after(created_after_timestamp).created_before(created_before_timestamp)
    }
  end

  def paypal_email
    card_visual.presence if paypal_charge_processor?
  end

  def charged_using_paypal_connect_account?
    merchant_account.present? && merchant_account.is_a_paypal_connect_account?
  end

  def seller_native_paypal_payment_enabled?
    seller.present? && seller.native_paypal_payment_enabled?
  end

  def paypal_refund_expired?
    created_at < 6.months.ago && card_type == CardType::PAYPAL
  end

  def paypal_fee_usd_cents
    return 0 unless paypal_charge_processor?
    return 0 if processor_fee_cents_currency.blank?
    return 0 if processor_fee_cents.to_i == 0

    get_usd_cents(processor_fee_cents_currency, processor_fee_cents)
  end
end
