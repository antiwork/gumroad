# frozen_string_literal: true

class KraPinValidationService
  attr_reader :kra_pin

  def initialize(kra_pin)
    @kra_pin = kra_pin
  end

  def process
    return false if kra_pin.blank?
    kra_pin.match?(/\A[A-Z]\d{9}[A-Z]\z/)
  end
end
