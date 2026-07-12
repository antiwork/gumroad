# frozen_string_literal: true

class GumroadRuntimeError < RuntimeError
  # The lower-level error this one wraps (e.g. a Stripe::InvalidRequestError), kept so
  # rescue sites can persist details like the processor's error code for debugging.
  attr_reader :original_error

  def initialize(message = nil, original_error: nil)
    @original_error = original_error
    super(message || original_error)
    set_backtrace(original_error.backtrace) if original_error
  end
end
