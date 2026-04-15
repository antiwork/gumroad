# frozen_string_literal: true

module LogRedactor
  FILTERED = "[FILTERED]"

  SENSITIVE_KEYS = %w[
    token
    stripe_publishable_key
    authorization
    paypal-auth-assertion
    verify_sign
  ].freeze

  module_function

  def redact(value)
    case value
    when Hash
      value.each_with_object({}) do |(k, v), acc|
        acc[k] = sensitive_key?(k) ? FILTERED : redact(v)
      end
    when Array
      value.map { |v| redact(v) }
    when OpenStruct
      redact(value.to_h)
    else
      value
    end
  end

  def sensitive_key?(key)
    SENSITIVE_KEYS.include?(key.to_s.downcase)
  end
end
