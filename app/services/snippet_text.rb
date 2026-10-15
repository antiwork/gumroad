# frozen_string_literal: true

# Shared cut for every snippet published from a seller's description (meta, og/twitter, JSON-LD),
# so they all end the same way.
module SnippetText
  module_function

  MAX_LENGTH = 160
  OMISSION = "..."

  # `truncate` appends the omission to whatever the cut kept, which doubled up "day to day." into "day to day....".
  TRAILING_PUNCTUATION = /[.,;:!?…]+\z/

  def truncate(text, length: MAX_LENGTH)
    text = text.to_s
    return text if text.length <= length

    prefix = text.truncate(length - OMISSION.length, separator: " ", omission: "")
    "#{prefix.sub(TRAILING_PUNCTUATION, "")}#{OMISSION}"
  end
end
