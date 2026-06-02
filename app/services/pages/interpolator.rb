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

    # The selection params (variant/quantity/PWYW price/recurrence) are
    # validated server-side and serialized into a JSON data attribute the
    # iframe's delegated checkout handler reads at click time, so a typo in the
    # agent's HTML falls back to the product's default checkout instead of
    # breaking the buyer's view.
    # Build the validator once so the product-derived lookups (variant names,
    # allowed recurrences) are memoized across every buy button on the page,
    # not re-queried per element.
    buy_button_validator = Pages::BuyButtonParams.new(product)
    fragment.css('[data-gumroad-action="buy"]').each do |node|
      selection = buy_button_validator.validate(node)
      node["data-gumroad-checkout-params"] = selection.to_json
      if node.name == "a"
        query = Rack::Utils.build_query({ wanted: true }.merge(selection))
        node["href"] = "/l/#{product.unique_permalink}?#{query}"
      end
    end

    fragment.to_html
  end
end
