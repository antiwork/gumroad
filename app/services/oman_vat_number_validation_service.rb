# frozen_string_literal: true

class OmanVatNumberValidationService
  attr_reader :vat_number

  def initialize(vat_number)
    @vat_number = vat_number
  end

  def process
    return false if vat_number.blank?
    vat_number.match?(/\AOM\d{10}\z/)
  end
end
