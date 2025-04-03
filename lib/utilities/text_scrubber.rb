# frozen_string_literal: true

class TextScrubber
  def self.format(text, opts = {})
    Loofah.fragment(text).to_text(opts).strip
  end
end
