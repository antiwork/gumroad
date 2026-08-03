# frozen_string_literal: true

# Infers Design > Fonts attribute values from the file extensions the seller already uploaded.
# `format` and `variable_font` are directly readable from the file itself, so classification
# never guesses at them: absence of a signal leaves the value unset rather than defaulting to
# a coin flip. `license` and `styles` are not inferable from an extension alone and are left
# for a seller to answer (gumroad-private#1788 scope: "leave the value unset rather than guess").
module Discover
  class FontsAttributeClassifier
    FORMAT_BY_EXTENSION = {
      "otf" => "OTF",
      "ttf" => "TTF",
      "woff2" => "WOFF2",
    }.freeze

    # Filenames carry the variable-font signal in either word order ("VF-Regular",
    # "Font-Variable"), so match on the standalone marker rather than a fixed phrase.
    VARIABLE_FONT_MARKERS = /\bvf\b|variable/i

    def initialize(link)
      @link = link
    end

    # Writes to `inferred_taxonomy_attribute_values`, never `taxonomy_attribute_values` — the
    # seller-entered key stays untouched, so a re-run can never clobber an explicit answer.
    def classify!
      @link.save_inferred_taxonomy_attribute_values(inferred_values)
    end

    # Pure read: what the classifier would infer right now, with no persistence. The backfill's
    # dry-run distribution report and any future editor preview both call this directly.
    def inferred_values
      extensions = font_file_extensions
      return {} if extensions.empty?

      values = {}
      values["format"] = FORMAT_BY_EXTENSION[extensions.first] if extensions.one? && FORMAT_BY_EXTENSION.key?(extensions.first)
      values["variable_font"] = true if @link.product_files.alive.any? { |file| VARIABLE_FONT_MARKERS.match?(file.name_displayable.to_s) }
      values
    end

    private
      # `alive_product_files` memoizes on the Link instance (see WithProductFiles) and is not
      # invalidated by `reload` — unsafe here, since the classifier runs from an after_commit
      # that can fire on the very instance whose files just changed. Query fresh instead.
      def font_file_extensions
        @link.product_files.alive.pluck(:filetype).compact.uniq & FORMAT_BY_EXTENSION.keys
      end
  end
end
