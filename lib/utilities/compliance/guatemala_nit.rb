# frozen_string_literal: true

# Stripe's individual.id_number check for Guatemala, measured live with distinct digits (test mode
# does not enforce it): 7-8 digits plus an optional trailing check letter K, 8-9 characters in
# total. "4829137", "482913K" and "482913-4" are refused; "4829137K", "4829137-K" and "48291374"
# pass. The check digit itself is not verified. Browser copy: app/javascript/utils/guatemalaNit.ts.
module Compliance
  module GuatemalaNit
    PATTERN = /\A\d{7,8}K?\z|\A\d{8,9}\z/

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
