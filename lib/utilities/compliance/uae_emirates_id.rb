# frozen_string_literal: true

# An Emirates ID is 15 digits, printed 3-4-7-1 with dashes. Stripe takes the digits only.
# Browser copy: app/javascript/utils/uaeEmiratesId.ts.
module Compliance
  module UaeEmiratesId
    DIGIT_COUNT = 15
    PATTERN = /\A(?:\d{15}|\d{3}-\d{4}-\d{7}-\d)\z/
    # [[:space:]] plus U+FEFF, the same set as the browser's /[\s\u0085]/.
    WHITESPACE = /[[:space:]\uFEFF]/

    # Dashes are dropped only from the printed grouping, so a malformed value keeps its separators
    # and still fails valid? instead of collapsing into 15 digits.
    def self.normalize(value)
      stripped = value.to_s.gsub(WHITESPACE, "")
      PATTERN.match?(stripped) ? stripped.delete("-") : stripped
    end

    def self.valid?(value)
      PATTERN.match?(value.to_s.gsub(WHITESPACE, ""))
    end

    ERROR_MESSAGE = "Your Emirates ID must be #{DIGIT_COUNT} digits (for example, 784-1234-1234567-1). " \
                    "Enter it exactly as it appears on your card — the dashes are optional."
  end
end
