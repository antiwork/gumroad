# frozen_string_literal: true

# Stripe accepts a Guatemala individual.id_number of 7-9 characters: a body of 6-8 digits plus an
# optional trailing check letter K, or 7-9 digits. The check digit is not verified. Browser copy:
# app/javascript/utils/guatemalaNit.ts.
module Compliance
  module GuatemalaNit
    PATTERN = /\A\d{6,8}K?\z|\A\d{8,9}\z/

    # Callers must send the normalized value, so what Stripe receives is what was length-checked.
    def self.normalize(value)
      value.to_s.gsub(/[[:space:]-]/, "").upcase
    end

    def self.valid?(value)
      normalized = normalize(value)
      normalized.length.between?(7, 9) && PATTERN.match?(normalized)
    end

    ERROR_MESSAGE = "Your NIT must be 6 to 8 digits followed by a check digit or the letter K " \
                    "(for example, 805813-K or 1234567-4). Enter it exactly as it appears on your document."
  end
end
