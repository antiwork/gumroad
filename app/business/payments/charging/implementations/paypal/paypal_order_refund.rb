# frozen_string_literal: true

class PaypalOrderRefund < ChargeRefund
  def initialize(response, capture_id)
    self.charge_processor_id = PaypalChargeProcessor.charge_processor_id
    self.charge_id = capture_id
    self.id = response.id
    @refund = response
  end
end
