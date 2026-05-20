# frozen_string_literal: true

class Ai::PageSanitizer
  ALLOWED_TAGS = %w[
    div span p h1 h2 h3 h4 h5 h6 a img ul ol li
    section header footer nav main article aside
    strong em b i u s br hr blockquote pre code
    table thead tbody tfoot tr th td
    figure figcaption button label input select option
    svg path circle rect line polyline polygon
    details summary
  ].freeze

  ALLOWED_ATTRIBUTES = %w[
    class id style
    src href alt title target rel
    width height loading
    data-gumroad-ref data-gumroad-field data-gumroad-action
    aria-label aria-hidden role
    type name value placeholder disabled
  ].freeze

  DANGEROUS_PATTERNS = [
    /javascript:/i,
    /on\w+\s*=/i,        # onclick, onload, etc.
    /<script/i,
    /<\/script/i,
    /expression\s*\(/i,  # CSS expression()
    /url\s*\(\s*['"]*javascript/i,
  ].freeze

  def self.sanitize(html)
    return "" if html.blank?

    # First pass: strip dangerous patterns
    cleaned = html.dup
    DANGEROUS_PATTERNS.each { |pattern| cleaned.gsub!(pattern, "") }

    # Second pass: use Rails sanitizer
    sanitizer = Rails::HTML5::SafeListSanitizer.new
    sanitizer.sanitize(
      cleaned,
      tags: ALLOWED_TAGS,
      attributes: ALLOWED_ATTRIBUTES,
    )
  end
end
