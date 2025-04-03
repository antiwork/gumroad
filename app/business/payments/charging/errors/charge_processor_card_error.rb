# frozen_string_literal: true

class ChargeProcessorCardError < ChargeProcessorError
  attr_reader :error_code, :charge_id

  def initialize(error_code, message = nil, original_error: nil, charge_id: nil)
    @error_code = error_code
    @charge_id = charge_id
    super(message, original_error:)
  end
end
