# frozen_string_literal: true

class PaypalChargeIntent < ChargeIntent
  def initialize(charge: nil)
    self.charge = charge
  end
end
