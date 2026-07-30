# frozen_string_literal: true

# Runs server-side at render time so crawlers and link previewers see real
# product values, not placeholders. Unknown markers pass through unchanged
# so the agent's fallback text renders instead of breaking the page.
class Pages::Interpolator
  FIELDS = {
    "name" => ->(product) { product.name.to_s },
    # The price a first-time buyer is charged: default offer code applied and, for memberships,
    # amount and wording from the default recurrence — the native /l/ page auto-applies both
    # (BestOfferCodeService, ProductPresenter::Card), so the plain set price here would disagree
    # with the page this markup replaces.
    "price" => ->(product) { product.price_formatted_verbose(for_default_duration: true, discounted: true).to_s },
    "description" => ->(product) { ActionView::Base.full_sanitizer.sanitize(product.description.to_s) }
  }.freeze

  PROFILE_FIELDS = {
    "name" => ->(user) { user.name_or_username.to_s },
    "bio" => ->(user) { user.bio.to_s }
  }.freeze

  # Fields a profile page can ask for about ONE product, via data-gumroad-product="<permalink>"
  # alongside data-gumroad-field. Values come from the per-request Pages::ProductPrices payload,
  # so "price" is visitor-localized where checkout can settle in that currency and "currency"
  # names the currency that price is in. "original-price" is the pre-discount amount, present
  # only while a default offer code discounts the product — write nothing inside that element
  # and it stays empty when there is no sale.
  PRODUCT_PRICE_FIELDS = {
    "price" => ->(entry) { entry[:price] },
    "original-price" => ->(entry) { entry[:original_price] },
    # Uppercased for markup: this surface is display text, where ISO codes read as "EUR". The
    # JSON blob keeps the lowercase code for scripts, matching gumroad-data conventions.
    "currency" => ->(entry) { entry[:currency_code].to_s.upcase.presence },
  }.freeze

  # Profiles have no buy affordance, so profile interpolation only fills in
  # display fields — no buy-button validation or ?wanted=true href rewriting.
  #
  # `prices` is a Pages::ProductPrices payload keyed by product permalink. It arrives per request
  # (never from the per-seller profile cache), which is what lets a profile page show a price that
  # is both visitor-localized and current: an element carrying data-gumroad-product plus
  # data-gumroad-field="price" gets that product's price written into it on every render.
  def self.interpolate_profile(html, profile:, prices: {})
    return html if html.blank?

    fragment = Loofah.fragment(html)
    fragment.css("[data-gumroad-field]").each do |node|
      field = node["data-gumroad-field"]
      permalink = node["data-gumroad-product"]
      # A data-gumroad-product attribute means the element is asking about one product, so the
      # user-level fields must not answer it — otherwise <span data-gumroad-product="x"
      # data-gumroad-field="name"> would render the seller's name inside a product card.
      if permalink.present?
        entry = prices[permalink]
        handler = PRODUCT_PRICE_FIELDS[field]
        value = entry && handler ? handler.call(entry) : nil
        # An unknown permalink or field leaves the element untouched, so whatever the page wrote
        # inside it still shows. Blanking it would turn a typo into a card with no price at all.
        node.inner_html = ERB::Util.h(value.to_s) if value.present?
      else
        handler = PROFILE_FIELDS[field]
        node.inner_html = ERB::Util.h(handler.call(profile)) if handler
      end
    end
    fragment.to_html
  end

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
