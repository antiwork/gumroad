# frozen_string_literal: true

# Outlook's Word engine frames any side whose border-style is solid even at zero width, so the
# universal `border: 0 solid` reset boxes every element there. A zero-width side becomes `none`.
module EmailZeroWidthBorderNormalizer
  extend self

  ZERO_WIDTH = /\A0(?:\.0+)?(?:[a-z]+|%)?\z/i
  SIDE_VALUE = /\A[a-z0-9.%-]+\z/i
  # A longhand for one side overrides the four-value forms read here, so such a style is left alone.
  SIDE_PROPERTY = /\Aborder-(?:top|right|bottom|left|block|inline)\b/i

  def normalize(html)
    return html unless html.include?("border-width")

    doc = Nokogiri::HTML(html)
    doc.css("[style]").each do |node|
      normalized = normalize_style(node["style"])
      node["style"] = normalized if normalized
    end
    doc.to_html
  end

  private
    def normalize_style(style)
      pairs = EmailCustomPropertyResolver.declarations(style)
      names = pairs.map { |name, _| name.downcase }
      return if names.any? { |name| name.match?(SIDE_PROPERTY) }

      style_index = names.rindex("border-style")
      width_index = names.rindex("border-width")
      return unless style_index && width_index

      styles = sides(pairs[style_index][1])
      widths = sides(pairs[width_index][1])
      return unless styles && widths

      visible = styles.zip(widths).map { |side_style, width| width.match?(ZERO_WIDTH) ? "none" : side_style }
      return if visible == styles

      pairs[style_index] = [pairs[style_index][0], shorthand(visible)]
      pairs.map { |name, value| "#{name}: #{value}" }.join("; ")
    end

    def sides(value)
      top, right, bottom, left = parts = value.split
      return unless parts.size.between?(1, 4) && parts.all? { |part| part.match?(SIDE_VALUE) }

      right ||= top
      [top, right, bottom || top, left || right]
    end

    def shorthand((top, right, bottom, left))
      return "#{top} #{right} #{bottom} #{left}" if right != left
      return "#{top} #{right} #{bottom}" if top != bottom

      top == right ? top : "#{top} #{right}"
    end
end
