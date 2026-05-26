# frozen_string_literal: true

# Runs server-side at render time so crawlers and link previewers see real
# product values, not placeholders. Unknown markers pass through unchanged
# so the agent's fallback text renders instead of breaking the page.
class Pages::Interpolator
  FIELDS = {
    "name" => ->(product) { product.name.to_s },
    "price" => ->(product) { product.price_formatted_verbose.to_s },
    "description" => ->(product) { ActionView::Base.full_sanitizer.sanitize(product.description.to_s) }
  }.freeze

  def self.interpolate(html, product:)
    return html if html.blank?

    fragment = Loofah.fragment(html)

    fragment.css("[data-gumroad-field]").each do |node|
      handler = FIELDS[node["data-gumroad-field"]]
      node.inner_html = ERB::Util.h(handler.call(product)) if handler
    end

    fragment.css('a[data-gumroad-action="buy"]').each do |a|
      a["href"] = "/l/#{product.unique_permalink}?wanted=true"
    end

    fragment.to_html
  end
end
