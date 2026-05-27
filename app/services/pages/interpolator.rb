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

    # The iframe sandbox omits top-navigation, so the buy button can't
    # navigate the buyer's tab itself. It messages the wrapper, which owns the
    # one checkout URL it will navigate to. `return false` stops an anchor (or a
    # button inside a form) from navigating/submitting the iframe to a dead
    # checkout-in-iframe. Match any element, not just <a>, so an agent-authored
    # <button>/<div> buy control still gets wired up instead of silently dying.
    fragment.css('[data-gumroad-action="buy"]').each do |node|
      node["onclick"] = "parent.postMessage('gumroad:checkout','*');return false;"
      node["href"] = "/l/#{product.unique_permalink}?wanted=true" if node.name == "a"
    end

    fragment.to_html
  end
end
