# frozen_string_literal: true

class PaypalChargeRefund < ChargeRefund
  include CurrencyHelper

  def initialize(paypal_refund_response, charge_id)
    self.charge_processor_id = PaypalChargeProcessor.charge_processor_id
    self.id = paypal_refund_response.RefundTransactionID
    self.charge_id = charge_id
    self.flow_of_funds = nil
  end
end
