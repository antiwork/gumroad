# frozen_string_literal: true

module InstallmentsHelper
  # Top-level rich-text blocks that should resolve their own text direction. Code blocks
  # (<pre>) are deliberately excluded because source code should always render
  # left-to-right, and embed/upsell wrapper <div>s are excluded because flipping their
  # direction would mirror their internal layout.
  AUTO_DIRECTION_BLOCK_TAGS = %w[p h1 h2 h3 h4 h5 h6 ul ol blockquote].freeze
  private_constant :AUTO_DIRECTION_BLOCK_TAGS

  def post_title_displayable(post:, url: nil)
    return content_tag(:span, post.subject, class: "title") unless url.present?
    link_to post.subject, url, target: "_blank", class: "title"
  end

  # Posts and emails can mix languages — for example an English intro followed by Hebrew
  # or Arabic paragraphs. A single dir="auto" on the outer container picks one base
  # direction from the first strongly-directional character in the whole message, and
  # every block below it inherits that direction, so the later RTL paragraphs would still
  # render left-to-right. Instead we mark each top-level text block with its own
  # dir="auto" so email clients resolve direction block by block (gumroad-private#1244).
  def with_per_block_text_direction(html)
    return html if html.blank?

    doc = Nokogiri::HTML.fragment(html)
    doc.children.each do |node|
      next unless node.element?
      next unless AUTO_DIRECTION_BLOCK_TAGS.include?(node.name)
      next if node["dir"].present?

      node["dir"] = "auto"
    end
    doc.to_html.html_safe
  end
end
