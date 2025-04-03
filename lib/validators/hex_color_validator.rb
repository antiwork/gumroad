# frozen_string_literal: true

class HexColorValidator < ActiveModel::EachValidator
  HEX_COLOR_REGEX = /^#[0-9a-f]{6}$/i

  def validate_each(record, attribute, value)
    return if self.class.matches?(value)

    record.errors.add(attribute, (options[:message] || "is not a valid hexadecimal color"))
  end

  def self.matches?(value)
    value.present? && HEX_COLOR_REGEX.match(value).present?
  end
end
