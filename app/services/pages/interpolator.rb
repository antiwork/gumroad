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
    "description" => ->(product) { ActionView::Base.full_sanitizer.sanitize(product.description.to_s) },
  }.freeze

  # Both fields read the summary that interpolate computes at most once per render.
  REVIEW_FIELDS = {
    # Trailing ".0" is stripped because the native page renders the rating as a JSON number,
    # where 4.0 prints as "4".
    "rating" => ->(summary) { summary.fetch(:average).to_s.delete_suffix(".0") },
    "review-count" => ->(summary) { summary.fetch(:count).to_s },
  }.freeze

  def self.review_summary(product)
    return unless product.display_product_reviews?

    stats = product.rating_stats
    return if stats[:count].zero?

    stats
  end

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
      # Presence of the attribute is what scopes, even valueless: the preview listener excludes
      # any node carrying it, so an empty marker answered by a profile field would make the
      # published page and the live preview disagree.
      unless permalink.nil?
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

    # :unloaded, not nil, because nil is the meaningful "reviews hidden or none yet" result and
    # must be memoized too.
    summary = :unloaded

    fragment.css("[data-gumroad-field]").each do |node|
      field = node["data-gumroad-field"]
      if (handler = FIELDS[field])
        value = handler.call(product)
      elsif (handler = REVIEW_FIELDS[field])
        summary = review_summary(product) if summary == :unloaded
        value = summary && handler.call(summary)
      else
        next
      end

      # nil means "leave the author's own copy in place" (reviews hidden, or none yet), matching
      # interpolate_profile. An empty STRING still writes, so a blank description keeps clearing
      # its placeholder as before.
      node.inner_html = ERB::Util.h(value) unless value.nil?
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
