# frozen_string_literal: true

module Product::StructuredData
  extend ActiveSupport::Concern
  include ActionView::Helpers::SanitizeHelper
  include CurrencyHelper

  SCHEMA_ORG_CONTEXT = "https://schema.org"
  AVAILABILITY_IN_STOCK = "#{SCHEMA_ORG_CONTEXT}/InStock"
  AVAILABILITY_LIMITED = "#{SCHEMA_ORG_CONTEXT}/LimitedAvailability"
  AVAILABILITY_SOLD_OUT = "#{SCHEMA_ORG_CONTEXT}/SoldOut"

  # host: threads the seller's custom domain through so the JSON-LD urls match the
  # canonical tag on the same page (PageMeta::Product). nil keeps the subdomain default.
  def structured_data(host: nil)
    if native_type == Link::NATIVE_TYPE_EBOOK
      build_ebook_structured_data(host:)
    else
      build_product_structured_data(host:)
    end
  end

  private
    def has_displayable_reviews?
      display_product_reviews? && reviews_count > 0
    end

    def build_ebook_structured_data(host: nil)
      url = long_url(host:)
      data = {
        "@context" => SCHEMA_ORG_CONTEXT,
        "@type" => "Book",
        "name" => name,
        "author" => {
          "@type" => "Person",
          "name" => user.name
        },
        "description" => product_description,
        "url" => url,
        "image" => social_share_image.presence,
        "sku" => unique_permalink
      }

      work_examples = build_book_work_examples
      data["workExample"] = work_examples if work_examples.any?
      data["offers"] = build_offer_data(url)
      data["aggregateRating"] = aggregate_rating_data if has_displayable_reviews?
      data.compact
    end

    def build_product_structured_data(host: nil)
      url = long_url(host:)
      data = {
        "@context" => SCHEMA_ORG_CONTEXT,
        "@type" => "Product",
        "name" => name,
        "description" => product_description,
        "url" => url,
        "image" => social_share_image.presence,
        "sku" => unique_permalink,
        "brand" => brand_data,
        "offers" => build_offer_data(url)
      }
      data["aggregateRating"] = aggregate_rating_data if has_displayable_reviews?
      data.compact
    end

    # Seller display name only — never fall back to User#display_name, whose
    # email fallback would leak the seller's address into public markup.
    def brand_data
      brand_name = user.name.presence
      return if brand_name.nil?

      { "@type" => "Brand", "name" => brand_name }
    end

    def build_offer_data(url)
      price_cents = minimum_offer_price_cents
      usd_cents = usd_offer_price_cents(price_cents)
      # Merchant Center's feed always reports USD (MerchantCenterFeedService); when
      # conversion succeeds here too, the price a crawler sees on this Offer matches
      # what the feed submitted for the same product. On conversion failure, fall back
      # to the native price/currency rather than showing a currency with no price.
      display_cents = usd_cents || price_cents
      currency = usd_cents.nil? ? price_currency_type.upcase : "USD"
      offer = {
        "@type" => "Offer",
        "priceCurrency" => currency,
        "availability" => availability_for_schema_org,
        "url" => url
      }
      offer["price"] = display_cents / subunit_to_unit(currency).to_f unless display_cents.nil?
      offer
    end

    def usd_offer_price_cents(cents)
      return nil if cents.nil?
      return cents if price_currency_type.to_s == "usd"

      rate = cached_rate(price_currency_type)
      return nil if rate.to_f <= 0

      get_usd_cents(price_currency_type, cents, rate:)
    rescue StandardError
      nil
    end

    def minimum_offer_price_cents
      base = lowest_base_price_cents
      return base if base.nil?
      base + (lowest_variant_price_difference_cents || 0)
    end

    def lowest_base_price_cents
      return (lowest_tier_price&.price_cents || 0) if is_tiered_membership

      candidates = [buy_price_cents]
      candidates << rental_price_cents if rentable?
      candidates << prices.alive.is_buy.minimum(:price_cents) if is_recurring_billing
      candidates.compact.min
    end

    def availability_for_schema_org
      return AVAILABILITY_IN_STOCK unless max_purchase_count?

      if remaining_for_sale_count&.zero?
        AVAILABILITY_SOLD_OUT
      else
        AVAILABILITY_LIMITED
      end
    end

    def aggregate_rating_data
      {
        "@type" => "AggregateRating",
        "ratingValue" => average_rating.round(1),
        "reviewCount" => reviews_count,
        "bestRating" => 5,
        "worstRating" => 1
      }
    end

    def build_book_work_examples
      book_files = alive_product_files.select(&:supports_isbn?)

      book_files.map do |file|
        work_example = {
          "@type" => "Book",
          "bookFormat" => "EBook",
          "name" => "#{name} (#{file.filetype.upcase})"
        }

        work_example["isbn"] = file.isbn if file.isbn.present?
        work_example
      end
    end

    def product_description
      (custom_summary.presence || strip_tags(html_safe_description).presence)
        .to_s
        .truncate(160)
        .presence
    end
end
