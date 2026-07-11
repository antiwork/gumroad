# frozen_string_literal: true

# Sanitizes the rich text content of a first-class page (Page#content) down to
# what the in-app rich text editor can produce. Pages built as full HTML go
# through Ai::PageSanitizer instead — this one is intentionally much stricter
# because rich text pages render inside the storefront layout, not in the
# sandboxed custom-HTML wrapper.
class Pages::RichContentSanitizer
  # The tags the TipTap-based RichTextEditor emits: paragraphs, headings,
  # lists, links, emphasis, quotes, code, images, and horizontal rules.
  ALLOWED_TAGS = %w[
    p h1 h2 h3 h4 h5 h6 ul ol li a strong b em i u s del blockquote hr br
    code pre img figure figcaption span div table thead tbody tr th td
  ].freeze

  ALLOWED_ATTRIBUTES = %w[href src alt title target rel class colspan rowspan].freeze

  def self.sanitize(html)
    return nil if html.blank?

    sanitizer = Rails::HTML5::SafeListSanitizer.new
    sanitizer.sanitize(html, tags: ALLOWED_TAGS, attributes: ALLOWED_ATTRIBUTES).presence
  end
end
