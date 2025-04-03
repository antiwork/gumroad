# frozen_string_literal: true

class BraintreeChargeIntent < ChargeIntent
  def initialize(charge: nil)
    self.charge = charge
  end
end
