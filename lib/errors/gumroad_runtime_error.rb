# frozen_string_literal: true

class GumroadRuntimeError < RuntimeError
  def initialize(message = nil, original_error: nil)
    super(message || original_error)
    set_backtrace(original_error.backtrace) if original_error
  end
end
