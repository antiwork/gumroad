# frozen_string_literal: true

class JsonValidator < ActiveModel::EachValidator
  def validate_each(record, attribute, value)
    unless JSON::Validator.validate(options[:schema], value)
      record.errors.add(attribute, options[:message] || "invalid.")
    end
  end
end
