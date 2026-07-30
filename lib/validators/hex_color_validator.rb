# frozen_string_literal: true

class HexColorValidator < ActiveModel::EachValidator
  # \A and \z, not ^ and $: Ruby's $ matches before a trailing newline, so "#ffffff\nbody{...}"
  # satisfied the old anchors. These values are interpolated straight into the storefront SCSS
  # (app/views/layouts/custom_styles/styles.scss.erb), so anything past the newline lands in the
  # rendered stylesheet.
  HEX_COLOR_REGEX = /\A#[0-9a-f]{6}\z/i
  SHORTHAND_HEX_COLOR_REGEX = /\A#([0-9a-f])([0-9a-f])([0-9a-f])\z/i
  CSS_HEX_COLOR_REGEX = /\A#(?:[0-9a-f]{3}|[0-9a-f]{6})\z/i

  def validate_each(record, attribute, value)
    return if self.class.matches?(value)

    record.errors.add(attribute, (options[:message] || "is not a valid hexadecimal color"))
  end

  def self.matches?(value)
    value.is_a?(String) && HEX_COLOR_REGEX.match?(value)
  end

  def self.normalize(value)
    return value unless value.is_a?(String)

    match = SHORTHAND_HEX_COLOR_REGEX.match(value)
    return value unless match

    "##{match.captures.map { "#{_1}#{_1}" }.join}".downcase
  end

  def self.safe_for_css?(value)
    value.is_a?(String) && CSS_HEX_COLOR_REGEX.match?(value)
  end
end
