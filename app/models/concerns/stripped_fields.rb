# frozen_string_literal: true

# Strips whitespace from start and end, and optionally:
# * converts blanks to nil
# * removes duplicate spaces
# * makes changes to the value
#
# Example:
#
#     include StrippedFields
#     stripped_fields :code, nilify_blanks: false
#     stripped_fields :email, transform: -> { _1.downcase }
#
# By default this also removes characters that are invisible to the person who typed them (see
# InvisibleCharacters), because for most fields quietly repairing the value is what you want: a
# name or a tax ID that picked up a bidirectional mark on the way through a copy/paste should
# just work. Pass `strip_invisible_characters: false` for a field where the value is an
# identity and the person needs to be TOLD it is wrong rather than have it changed underneath
# them — email addresses being the case that matters, since a silently altered address means
# the account receives no mail at all and nobody can tell why.
module StrippedFields
  extend ActiveSupport::Concern

  class_methods do
    def stripped_fields(*fields, remove_duplicate_spaces: true, transform: nil, nilify_blanks: true, strip_invisible_characters: true, **options)
      before_validation(options) do |object|
        fields.each do |field|
          StrippedFields::StrippedField.before_validation(
            object,
            field,
            remove_duplicate_spaces:,
            transform:,
            nilify_blanks:,
            strip_invisible_characters:
          )
        end
      end
    end
  end

  module StrippedField
    extend self

    def before_validation(object, field, remove_duplicate_spaces:, transform:, nilify_blanks:, strip_invisible_characters: true)
      value = object.read_attribute(field)
      value = strip(value, strip_invisible_characters:)
      value = remove_duplicate_spaces(value, enabled: remove_duplicate_spaces)
      value = transform(value, transform:)
      value = nilify_blanks(value, enabled: nilify_blanks)
      object.send("#{field}=", value)
    end

    private
      # The invisible-character set lives in InvisibleCharacters so that this strip helper, the
      # email validation that rejects an address outright, and the models that normalize an
      # email on their own all agree on exactly which characters count as invisible.
      #
      # When strip_invisible_characters is false we leave the invisible characters in place so
      # that the field's own validation gets to see them and reject the value. Removing them
      # here would hide the problem: validation would pass against a value the person never
      # typed.
      def strip(value, strip_invisible_characters:)
        value = InvisibleCharacters.remove(value) if strip_invisible_characters
        value.to_s.strip
      end

      def remove_duplicate_spaces(value, enabled:)
        value = value.squeeze(" ") if enabled
        value
      end

      def transform(value, transform:)
        value = transform.call(value) if transform.present? && value.present?
        value
      end

      def nilify_blanks(value, enabled:)
        value = nil if enabled && value.blank?
        value
      end
  end
end
