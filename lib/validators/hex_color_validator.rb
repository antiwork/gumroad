# frozen_string_literal: true

class HexColorValidator < ActiveModel::EachValidator
  HEX_COLOR_REGEX = /\A#[0-9a-f]{6}\z/i
  CSS_HEX_COLOR_REGEX = /\A#(?:[0-9a-f]{3}|[0-9a-f]{6})\z/i

  def validate_each(record, attribute, value)
    return if self.class.matches?(value)

    record.errors.add(attribute, (options[:message] || "is not a valid hexadecimal color"))
  end

  def self.matches?(value)
    value.present? && HEX_COLOR_REGEX.match(value).present?
  end

  def self.safe_for_css?(value)
    value.is_a?(String) && CSS_HEX_COLOR_REGEX.match?(value)
  end
end
