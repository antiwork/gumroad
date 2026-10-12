# frozen_string_literal: true

module Compliance
  module DominicanRepublicCie
    PATTERN = /\A\d{3}-\d{7}-\d\z/

    def self.valid?(value)
      PATTERN.match?(value.to_s)
    end

    ERROR_MESSAGE = "Your Cédula de identidad y electoral (CIE) must be 13 characters including the dashes " \
                    "(for example, 123-1234567-1). A passport number is not accepted."
  end
end
