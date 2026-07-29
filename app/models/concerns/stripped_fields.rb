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

  class_methods do
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

    # Characters that are invisible to the person typing but are still real bytes we store.
    # They arrive from copy/paste (a bidi mark travels with text copied out of an RTL
    # document), from RTL-locale keyboards, and from PDFs that use a soft hyphen as a
    # line-break hint. Because they render as nothing, a value containing one looks
    # byte-for-byte correct to the user and to us, while every downstream system that
    # matches on the value fails: an email address with a leading U+200F is accepted at
    # signup and then hard-bounces at the mail provider, and a prefix search for the
    # address the user believes they typed can never find their row.
    #
    # Deliberately EXCLUDED, even though they sit inside the same Unicode block:
    #   * U+200C ZERO WIDTH NON-JOINER — carries meaning in Persian, Arabic and several
    #     Indic scripts (it is what keeps "می‌روم" two words). Deleting it corrupts names.
    #   * U+200D ZERO WIDTH JOINER — the glue inside multi-codepoint emoji (family and
    #     flag sequences) and inside Indic conjuncts. Sellers put emoji in display names,
    #     so deleting it would visibly mangle them.
    # Both are semantic content, not formatting, which is why this is a hand-picked list
    # rather than the whole U+200B–U+200F range.
    INVISIBLE_FORMAT_CHARS = /[\u00AD\u200B\u200E\u200F\u2060\uFEFF]/
    private_constant :INVISIBLE_FORMAT_CHARS

    # Unicode space separators. Ruby's String#strip only knows ASCII whitespace, so these
    # survive it and then behave like content. Folding them to a plain space (rather than
    # deleting them) preserves the word boundary the user intended — "Ada Lovelace" typed
    # with a no-break space stays two words instead of becoming "AdaLovelace" — and lets
    # the existing strip/squeeze steps below do the rest of the work.
    UNICODE_SPACES = /[\u00A0\u1680\u2000-\u200A\u202F\u205F\u3000]/
    private_constant :UNICODE_SPACES

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
        value.to_s
             .gsub(INVISIBLE_FORMAT_CHARS, "")
             .gsub(UNICODE_SPACES, " ")
             .strip
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
