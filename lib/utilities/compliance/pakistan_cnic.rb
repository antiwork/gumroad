# frozen_string_literal: true

# A Pakistani CNIC is 13 digits, printed 5-7-1 with dashes ("42101-1234567-1"). Sellers copy it as
# printed, but Stripe's individual.id_number takes the digits only, so callers must normalize what
# they send — the length guard counts digits, and a dashed value would reach Stripe longer than the
# guard measured. Browser copy: app/javascript/utils/pakistanCnic.ts. Changing DIGIT_COUNT also
# means editing that file, which states the bound to sellers.
module Compliance
  module PakistanCnic
    DIGIT_COUNT = 13

    def self.normalize(value)
      value.to_s.gsub(/\D/, "")
    end

    def self.valid?(value)
      normalize(value).length == DIGIT_COUNT
    end

    # Names the example in the shape the card is printed with, so a seller who typed a truncated
    # number can see which part went missing; the dashes are called out as optional because both
    # forms are accepted and stripped before Stripe sees them.
    ERROR_MESSAGE = "Your CNIC must be #{DIGIT_COUNT} digits (for example, 12345-1234567-1). " \
                    "Enter it exactly as it appears on your card — the dashes are optional."
  end
end
