# frozen_string_literal: true

module Wishlist::StructuredData
  extend ActiveSupport::Concern
  include CurrencyHelper

  SCHEMA_ORG_CONTEXT = "https://schema.org"

  # Matches WishlistPresenter's first page so the JSON-LD only claims what the
  # initial HTML actually renders.
  ITEM_LIST_LIMIT = 20

  def structured_data
    products = alive_wishlist_products.includes(product: :user).limit(ITEM_LIST_LIMIT).map(&:product).uniq
    return {} if products.empty?

    {
      "@context" => SCHEMA_ORG_CONTEXT,
      "@type" => "ItemList",
      "name" => name,
      "numberOfItems" => products.size,
      "itemListElement" => products.each_with_index.map do |product, index|
        {
          "@type" => "ListItem",
          "position" => index + 1,
          "item" => structured_data_item(product)
        }
      end
    }
  end

  private
    def structured_data_item(product)
      url = product.long_url
      item = {
        "@type" => "Product",
        "name" => product.name,
        "url" => url
      }

      # A live product can have no live Price record (e.g. rent-only after its
      # rental price was removed) — skip the offer rather than crash the page,
      # same nil guard as PageMeta::Product. The currency can also be NULL on
      # legacy rows, and NULL matches a stale Price row whose own currency is
      # NULL, so a price can survive a blank currency; an amount with no
      # currency is meaningless, so skip the offer for those rows too.
      price_cents = product.price_cents
      currency = product.price_currency_type
      unless price_cents.nil? || currency.blank?
        item["offers"] = {
          "@type" => "Offer",
          "price" => (price_cents / unit_scaling_factor(currency).to_f).round(2),
          "priceCurrency" => currency.upcase,
          "url" => url
        }
      end

      item
    end
end
