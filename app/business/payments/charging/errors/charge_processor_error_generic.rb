# frozen_string_literal: true

class ChargeProcessorErrorGeneric < ChargeProcessorError
  attr_reader :error_code

  def initialize(error_code, message: nil, original_error: nil)
    @error_code = error_code
    super(message, original_error:)
  end
end
