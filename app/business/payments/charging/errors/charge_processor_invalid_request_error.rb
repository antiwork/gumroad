# frozen_string_literal: true

class ChargeProcessorInvalidRequestError < ChargeProcessorError
  def initialize(message = nil, original_error: nil, processor_error_code: nil)
    @explicit_processor_error_code = processor_error_code
    super(message, original_error:)
  end

  # The processor's own error code (e.g. Stripe's "payment_intent_invalid_parameter"), when
  # the wrapped error exposes one. Rescue sites persist this into stripe_error_code so a
  # failed purchase records *why* the processor rejected the request instead of leaving the
  # column blank. PayPal has no exception object to wrap — its rejection arrives as a parsed
  # response body — so those call sites pass the issue string in directly.
  def processor_error_code
    return @explicit_processor_error_code if @explicit_processor_error_code.present?
    original_error.code if original_error.respond_to?(:code)
  end
end
