# frozen_string_literal: true

# Gmail and Outlook drop custom-property declarations, so every inlined `var(--x)` computes to its
# initial value there and the email renders as unstyled HTML. This resolves them against the
# inheritance chain of each element's own inline declarations, seeded by the stylesheet's :root.
module EmailCustomPropertyResolver
  extend self

  MAX_DEPTH = 8
  VAR_PATTERN = /var\(\s*(--[\w-]+)\s*(?:,((?:[^()]|\([^()]*\))*))?\)/
  MODERN_RGB = %r{\brgba?\(\s*(\d+(?:\.\d+)?)[\s,]+(\d+(?:\.\d+)?)[\s,]+(\d+(?:\.\d+)?)\s*(?:[/,]\s*(\d*\.?\d+%?))?\s*\)}

  def root_properties(css)
    css.to_s.scan(/:root\s*\{([^{}]*)\}/).each_with_object({}) do |(block), vars|
      declarations(block).each { |name, value| vars[name] = value if name.start_with?("--") }
    end
  end

  def resolve(html, root_vars)
    return html unless html.include?("var(--")

    doc = Nokogiri::HTML(html)
    (doc.root ? [doc.root] : []).each { |node| resolve_node(node, root_vars) }
    doc.to_html
  end

  private
    def resolve_node(node, inherited)
      vars = inherited
      if node["style"].present?
        pairs = declarations(node["style"])
        own = pairs.select { |name, _| name.start_with?("--") }.to_h
        vars = inherited.merge(own.transform_values { |value| substitute(value, inherited.merge(own)) })
        node["style"] = pairs.filter_map do |name, value|
          next if name.start_with?("--")

          "#{name}: #{modernize(substitute(value, vars))}"
        end.join("; ")
        node.remove_attribute("style") if node["style"].empty?
      end
      node.element_children.each { |child| resolve_node(child, vars) }
    end

    def substitute(value, vars, depth = 0)
      return value if depth > MAX_DEPTH || !value.include?("var(")

      resolved = value.gsub(VAR_PATTERN) do
        name, fallback = Regexp.last_match(1), Regexp.last_match(2)
        vars[name] || fallback&.strip || Regexp.last_match(0)
      end
      resolved == value ? value : substitute(resolved, vars, depth + 1)
    end

    # Space-separated rgb() is a CSS Color 4 form that older Outlook engines do not parse.
    def modernize(value)
      value.gsub(MODERN_RGB) do
        r, g, b, a = Regexp.last_match.captures
        a ? "rgba(#{r}, #{g}, #{b}, #{a})" : "rgb(#{r}, #{g}, #{b})"
      end
    end

    def declarations(block)
      parts = []
      current = +""
      depth = 0
      quote = nil
      block.each_char do |char|
        if quote
          quote = nil if char == quote
        elsif char == "\"" || char == "'"
          quote = char
        elsif char == "("
          depth += 1
        elsif char == ")"
          depth -= 1
        elsif char == ";" && depth <= 0
          parts << current
          current = +""
          next
        end
        current << char
      end
      parts << current
      parts.filter_map do |part|
        name, value = part.split(":", 2)
        next if value.nil? || name.strip.empty?

        [name.strip, value.strip]
      end
    end
end
