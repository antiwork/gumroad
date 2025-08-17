# frozen_string_literal: true

class EmailValidator < ActiveModel::EachValidator
  EMAIL_REGEX = /\A[^@\s]+@[^@\s]+\z/

  def validate_each(record, attribute, value)
    return if value.blank?

    if value.is_a?(String) && !valid_email_format?(value)
      record.errors.add(attribute, options[:message] || :invalid_email)
    end
  end

  private

  def valid_email_format?(email)
    email.match?(EMAIL_REGEX) && email.length <= 254
  end
end
