# frozen_string_literal: true

# Stripe refuses a Guatemala individual.id_number unless it is 7-8 digits plus an optional trailing
# K, or 8-9 digits, 8-9 characters in total. The check digit is not verified. Browser copy:
# app/javascript/utils/guatemalaNit.ts.
module Compliance
  module GuatemalaNit
    PATTERN = /\A\d{7,8}K?\z|\A\d{8,9}\z/

    # Callers must send the normalized value, so what Stripe receives is what was length-checked.
    def self.normalize(value)
      value.to_s.gsub(/[[:space:]-]/, "").upcase
    end

    def self.valid?(value)
      normalized = normalize(value)
      normalized.length.between?(8, 9) && PATTERN.match?(normalized)
    end

    ERROR_MESSAGE = "Your NIT must be 7 or 8 digits followed by a check digit or the letter K " \
                    "(for example, 1234567-8 or 1234567-K). Enter it exactly as it appears on your document."
  end
end
