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

  def initialize(seller, ip:)
    @seller = seller
    @ip = ip
  end

  def build
    products.each_with_object({}) do |product, prices|
      prices[product.general_permalink] = entry_for(product)
    end
  end

  private
    attr_reader :seller, :ip

    # Same scope, ordering and cap as Pages::ProfileData#products so the two payloads describe
    # the same set of products in the same order. The associations are the ones the buyer-currency
    # gate and the price formatting read, loaded up front because a large catalogue would
    # otherwise run them once per product.
    def products
      seller.products.alive.not_archived.not_draft
            .includes(:alive_prices, :installment_plan, :user, tiers: :alive_prices)
            .order(created_at: :desc).limit(Pages::ProfileData::MAX_ITEMS)
    end

    def entry_for(product)
      # display_price_cents with no arguments is what Link#price_formatted_verbose formats, so the
      # cents we emit and the string a page renders describe the same amount.
      price_cents = product.display_price_cents
      display = localizable?(product) ? buyer_currency_display_props(product:, price_cents:, ip:) : nil

      if display && display[:display_mode] == "buyer_local" && display[:buyer_local_price_cents].present?
        {
          price: localized_price_formatted(product, display),
          price_cents: display[:buyer_local_price_cents],
          currency_code: display[:buyer_currency_shown],
          localized: true,
        }
      else
        {
          price: product.price_formatted_verbose,
          price_cents:,
          currency_code: product.price_currency_type.to_s.downcase,
          localized: false,
        }
      end
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
      formatted = MoneyFormatter.format(
        display[:buyer_local_price_cents],
        display[:buyer_currency_shown].to_sym,
        no_cents_if_whole: true,
        symbol: true
      )
      "#{formatted}#{product.has_customizable_price_option? ? '+' : ''}"
    end

    # One GeoIP lookup per render rather than one per product: the visitor's country does not
    # change between the cards on a page.
    def buyer_currency_for_ip(lookup_ip)
      @buyer_currency_for_ip ||= {}
      return @buyer_currency_for_ip[lookup_ip] if @buyer_currency_for_ip.key?(lookup_ip)

      @buyer_currency_for_ip[lookup_ip] = super
    end
end
