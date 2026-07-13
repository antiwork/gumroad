# frozen_string_literal: true

class ChargeProcessorInvalidRequestError < ChargeProcessorError
  # The processor's own error code (e.g. Stripe's "payment_intent_invalid_parameter"), when
  # the wrapped error exposes one. Rescue sites persist this into stripe_error_code so a
  # failed purchase records *why* the processor rejected the request instead of leaving the
  # column blank.
  def processor_error_code
    original_error.code if original_error.respond_to?(:code)
  end
end
