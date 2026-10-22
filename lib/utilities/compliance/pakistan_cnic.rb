# frozen_string_literal: true

# A Pakistani CNIC is 13 digits, printed 5-7-1 with dashes. Stripe takes the digits only.
# Browser copy: app/javascript/utils/pakistanCnic.ts.
module Compliance
  module PakistanCnic
    DIGIT_COUNT = 13
    PATTERN = /\A(?:\d{13}|\d{5}-\d{7}-\d)\z/
    # [[:space:]] plus U+FEFF, the same set as the browser's /[\s\u0085]/.
    WHITESPACE = /[[:space:]\uFEFF]/

    # Dashes are dropped only from the printed grouping, so a malformed value keeps its separators
    # and still fails valid? instead of collapsing into 13 digits.
    def self.normalize(value)
      stripped = value.to_s.gsub(WHITESPACE, "")
      PATTERN.match?(stripped) ? stripped.delete("-") : stripped
    end

    def self.valid?(value)
      PATTERN.match?(value.to_s.gsub(WHITESPACE, ""))
    end

    ERROR_MESSAGE = "Your CNIC must be #{DIGIT_COUNT} digits (for example, 12345-1234567-1). " \
                    "Enter it exactly as it appears on your card — the dashes are optional."
  end
end
