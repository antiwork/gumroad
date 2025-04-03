# frozen_string_literal: true

class FirsTinValidationService
  attr_reader :tin

  def initialize(tin)
    @tin = tin
  end

  def process
    return false if tin.blank?
    tin.match?(/^\d{8}-\d{4}$/)
  end
end
