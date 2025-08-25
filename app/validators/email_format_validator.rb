# frozen_string_literal: true

class EmailFormatValidator < ActiveModel::EachValidator
  # To reduce invalid email address errors, we enforcing the same email regex as the front end
  EMAIL_REGEX = /\A(?=.{3,255}$)(                                         # between 3 and 255 characters
                ([^@\s()\[\],.<>;:\\"]+(\.[^@\s()\[\],.<>;:\\"]+)*)       # cannot start with or have consecutive .
                |                                                         # or
                (".+"))                                                   # local part can be in quotes
                @
                ((\[[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\])     # IP address
                |                                                         # or
                (([a-zA-Z\-0-9]+\.)+[a-zA-Z]{2,})                         # domain can only alphabets and . -
                )\z/x

  class << self
    def valid?(email)
      return false if email.blank?
      email.to_s.match?(EMAIL_REGEX)
    end
  end

  def validate_each(record, attribute, value)
    return if value.nil? && options[:allow_nil]
    return if value.blank? && options[:allow_blank]

    unless self.class.valid?(value)
      record.errors.add(attribute, options[:message] || :invalid)
    end
  end
end
