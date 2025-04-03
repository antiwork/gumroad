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
module StrippedFields
  extend ActiveSupport::Concern

  module ClassMethods
    def stripped_fields(*fields, remove_duplicate_spaces: true, transform: nil, nilify_blanks: true, **options)
      before_validation(options) do |object|
        fields.each do |field|
          StrippedFields::StrippedField.before_validation(
            object,
            field,
            remove_duplicate_spaces:,
            transform:,
            nilify_blanks:
          )
        end
      end
    end
  end

  module StrippedField
    extend self

    def before_validation(object, field, remove_duplicate_spaces:, transform:, nilify_blanks:)
      value = object.read_attribute(field)
      value = strip(value)
      value = remove_duplicate_spaces(value, enabled: remove_duplicate_spaces)
      value = transform(value, transform:)
      value = nilify_blanks(value, enabled: nilify_blanks)
      object.send("#{field}=", value)
    end

    private
      def strip(value)
        value.to_s.strip || ""
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
