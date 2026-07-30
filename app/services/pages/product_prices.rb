# frozen_string_literal: true

# Per-request product prices for custom-HTML profile pages, localized to the visitor's
# currency wherever checkout could actually settle in it.
#
# Pages::ProfileData — the `gumroad-data` payload — is cached per seller, so by construction it
# cannot carry a visitor-derived value, and its `price` is the seller's own currency. This service
# is the uncached, per-request half: it is rebuilt on every render, so its prices are both
# visitor-localized and immune to the profile cache serving a stale price after an edit.
#
# It feeds two surfaces from one computation, so they can never disagree:
#   - the `gumroad-prices` JSON blob, for pages that build their cards in JavaScript
#   - Pages::Interpolator's product-scoped `price` field, for pages that write the price as markup
#
# Keyed by Link#general_permalink (the product's custom permalink when it has one, else its
# unique permalink) — the same identifier that appears at the end of every product url the
# `gumroad-data` payload already emits, so a page can key off a value it already holds.
class Pages::ProductPrices
  include CurrencyHelper

  def self.build(seller, ip:)
    new(seller, ip:).build
  end

  # Whether a page can consume this payload at all. Its only consumers live inside the page's
  # own HTML — the interpolator answers data-gumroad-product elements, and a script can only
  # find the blob by its literal id — so a page containing neither string cannot read a price,
  # and the whole per-request build (queries, GeoIP, formatting) is skipped for it.
  def self.referenced_in?(html)
    html.to_s.match?(/data-gumroad-product|gumroad-prices/)
  end

  def initialize(seller, ip:)
    @seller = seller
    @ip = ip
  end

  def build
    loaded = products.to_a
    warm_offer_code_uses(loaded)
    loaded.each_with_object({}) do |product, prices|
      prices[product.general_permalink] = entry_for(product)
    end
  end

  private
    attr_reader :seller, :ip

    # Same scope, ordering and cap as Pages::ProfileData#products so the two payloads describe
    # the same set of products in the same order. The associations are the ones
    # Product::Prices#lowest_variant_price_difference_cents needs to take its preloaded path
    # (:skus plus every alive variant under every alive category — miss either and it falls back
    # to two queries per product), plus what the buyer-currency gate and formatting read. This
    # runs uncached on a public page for up to MAX_ITEMS products, so the preload is load-bearing.
    def products
      # default_tier is its own has-one-through — `tiers:` does not populate it, and
      # show_customizable_price_indicator? reads it per tiered membership.
      seller.products.alive.not_archived.not_draft
            .includes(:alive_prices, :installment_plan, :user, :skus, :default_offer_code,
                      tiers: :alive_prices, default_tier: :alive_prices,
                      variant_categories_alive: :alive_variants)
            .order(created_at: :desc).limit(Pages::ProfileData::MAX_ITEMS)
    end

    # Seeds the per-request memo discounted_price_cents reads with one grouped aggregate for
    # every capped default code on the page. Without this, each DISTINCT capped code costs its
    # own purchases SUM — up to MAX_ITEMS of them on this uncached path when every product
    # carries its own code.
    def warm_offer_code_uses(products)
      cache = (Current.default_offer_code_uses_left ||= {})
      capped = products.filter_map(&:default_offer_code)
                       .select(&:cap_exhaustible_for_quoting?)
                       .uniq(&:id)
                       .reject { |code| cache.key?(code.id) }
      return if capped.empty?

      cache.merge!(OfferCode.uses_left_by_id(capped))
    end

    def entry_for(product)
      # The number a buyer would be charged, computed exactly as ProductPresenter::Card computes it
      # for the native grid — including `for_default_duration`, without which a tiered membership
      # quotes its cheapest recurrence's amount here and its default recurrence's amount there.
      base_price_cents = product.display_price_cents(for_default_duration: true)
      price_cents = product.discounted_price_cents(base_price_cents)
      display = localizable?(product) ? buyer_currency_display_props(product:, price_cents:, ip:) : nil

      if display && display[:display_mode] == "buyer_local" && display[:buyer_local_price_cents].present?
        localized_entry(product, display, base_price_cents:, price_cents:)
      else
        own_currency_entry(product, base_price_cents:, price_cents:)
      end
    end

    def localized_entry(product, display, base_price_cents:, price_cents:)
      entry = {
        price: localized_price_formatted(product, display),
        price_cents: display[:buyer_local_price_cents],
        currency_code: display[:buyer_currency_shown],
        localized: true,
      }
      # The pre-discount amount, converted with the same rate as the price so the pair can't
      # drift — mirroring buyer_local_price_props, which is how the native card localizes its
      # strikethrough. Amount only: the native card never suffixes the struck-through number.
      if price_cents < base_price_cents
        original_cents = buyer_local_price_cents(
          price_cents: base_price_cents,
          from_currency: product.price_currency_type,
          to_currency: display[:buyer_currency_shown],
          rate: BigDecimal(display[:rate].to_s)
        )
        if original_cents.present?
          entry[:original_price] = format_in_buyer_currency(original_cents, display[:buyer_currency_shown])
          entry[:original_price_cents] = original_cents
        end
      end
      entry
    end

    def own_currency_entry(product, base_price_cents:, price_cents:)
      entry = {
        price: product.price_formatted_verbose_for_price_cents(
          price_cents, recurrence: product.subscription_duration, duration_in_months: product.duration_in_months
        ),
        price_cents:,
        currency_code: product.price_currency_type.to_s.downcase,
        localized: false,
      }
      if price_cents < base_price_cents
        entry[:original_price] = product.display_price_for_price_cents(base_price_cents)
        entry[:original_price_cents] = base_price_cents
      end
      entry
    end

    # The product shapes checkout refuses to quote (memberships, preorders, free trials,
    # commissions, installment plans) are charged in canonical USD, so a converted price here
    # would be a number no buyer is ever charged. buyer_currency_settleable? already excludes
    # them, but only while the checkout-eligibility flag is on — it short-circuits to true
    # otherwise, which for a membership would drop the recurrence wording from a price whose
    # amount only makes sense with it ("€11.20" for what is €11.20 a month).
    def localizable?(product)
      !buyer_currency_unquotable_product?(product)
    end

    # Mirrors Link#price_formatted_verbose, in the buyer's currency, minus the recurrence suffix
    # that method appends — localizable? above keeps every recurring shape out of this branch.
    def localized_price_formatted(product, display)
      formatted = format_in_buyer_currency(display[:buyer_local_price_cents], display[:buyer_currency_shown])
      "#{formatted}#{product.has_customizable_price_option? ? '+' : ''}"
    end

    def format_in_buyer_currency(cents, currency)
      MoneyFormatter.format(cents, currency.to_sym, no_cents_if_whole: true, symbol: true)
    end

    # One GeoIP lookup per render rather than one per product: the visitor's country does not
    # change between the cards on a page.
    def buyer_currency_for_ip(lookup_ip)
      @buyer_currency_for_ip ||= {}
      return @buyer_currency_for_ip[lookup_ip] if @buyer_currency_for_ip.key?(lookup_ip)

      @buyer_currency_for_ip[lookup_ip] = super
    end

    # Same reasoning for the rate, which is a Redis read per call: every product priced in the
    # same currency converts through the same pair.
    def buyer_local_currency_rate(from_currency:, to_currency:)
      @buyer_local_currency_rate ||= {}
      key = [from_currency.to_s.downcase, to_currency.to_s.downcase]
      return @buyer_local_currency_rate[key] if @buyer_local_currency_rate.key?(key)

      @buyer_local_currency_rate[key] = super
    end
end
