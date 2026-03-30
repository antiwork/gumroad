# frozen_string_literal: true

module Product::StructuredData
  extend ActiveSupport::Concern
  include ActionView::Helpers::SanitizeHelper

  SCHEMA_ORG_CONTEXT = "https://schema.org"
  AVAILABILITY_IN_STOCK = "#{SCHEMA_ORG_CONTEXT}/InStock"
  AVAILABILITY_LIMITED = "#{SCHEMA_ORG_CONTEXT}/LimitedAvailability"
  AVAILABILITY_SOLD_OUT = "#{SCHEMA_ORG_CONTEXT}/SoldOut"

  def structured_data
    if native_type == Link::NATIVE_TYPE_EBOOK
      build_ebook_structured_data
    elsif has_displayable_reviews?
      build_product_structured_data
    else
      {}
    end
  end

  private
    def has_displayable_reviews?
      display_product_reviews? && reviews_count > 0
    end

    def build_ebook_structured_data
      url = long_url
      data = {
        "@context" => SCHEMA_ORG_CONTEXT,
        "@type" => "Book",
        "name" => name,
        "author" => {
          "@type" => "Person",
          "name" => user.name
        },
        "description" => product_description,
        "url" => url
      }

      work_examples = build_book_work_examples
      data["workExample"] = work_examples if work_examples.any?
      data["offers"] = build_offer_data(url)
      data["aggregateRating"] = aggregate_rating_data if has_displayable_reviews?
      data.compact
    end

    def build_product_structured_data
      url = long_url
      {
        "@context" => SCHEMA_ORG_CONTEXT,
        "@type" => "Product",
        "name" => name,
        "description" => product_description,
        "url" => url,
        "offers" => build_offer_data(url),
        "aggregateRating" => aggregate_rating_data
      }.compact
    end

    def build_offer_data(url)
      price_cents = minimum_offer_price_cents
      offer = {
        "@type" => "Offer",
        "priceCurrency" => price_currency_type.upcase,
        "availability" => availability_for_schema_org,
        "url" => url
      }
      offer["price"] = price_cents / 100.0 unless price_cents.nil?
      offer
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
