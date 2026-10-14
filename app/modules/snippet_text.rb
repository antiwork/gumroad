# frozen_string_literal: true

# One cut rule for every snippet we publish from a seller's description: the product page
# meta description, the og/twitter description that link previews render verbatim, the
# wishlist page meta, and the product JSON-LD description. They are the same string, so
# they have to be cut the same way — three call sites used to carry their own `truncate`.
module SnippetText
  module_function

  # Roughly what Google shows before it rewrites the snippet. Everything past this is pure
  # head weight, and a longer og:description just gets clipped by the preview renderer.
  MAX_LENGTH = 160

  # The omission appended when a description is longer than the cap.
  OMISSION = "..."

  # Punctuation that already ends a sentence or clause. Rails' `truncate` appends the
  # omission to whatever the cut left behind, so a description whose cut lands right after
  # a period published "…the meals I cook day to day." plus the omission — "…day to day....".
  # Replace that punctuation with the omission instead of following it.
  TRAILING_PUNCTUATION = /[.,;:!?]+\z/

  # Public: Cap a description at a search-snippet length, cutting on a word boundary.
  #
  # Returns the text unchanged when it already fits.
  def truncate(text, length: MAX_LENGTH)
    text = text.to_s
    return text if text.length <= length

    # Budget the omission inside the cap so the result never exceeds it. Passing
    # `separator:` keeps the last word whole; passing `omission: ""` keeps the omission
    # out of the cut so we can decide what to do with the punctuation it lands on.
    prefix = text.truncate(length - OMISSION.length, separator: " ", omission: "")
    "#{prefix.sub(TRAILING_PUNCTUATION, "")}#{OMISSION}"
  end
end
