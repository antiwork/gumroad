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
      # same nil guard as PageMeta::Product.
      price_cents = product.price_cents
      unless price_cents.nil?
        item["offers"] = {
          "@type" => "Offer",
          "price" => (price_cents / unit_scaling_factor(product.price_currency_type).to_f).round(2),
          "priceCurrency" => product.price_currency_type.upcase,
          "url" => url
        }
      end

      item
    end
end
