# frozen_string_literal: true

class ProductPresenter::Card
  include Rails.application.routes.url_helpers
  include ProductsHelper

  ASSOCIATIONS = [
    :alive_prices, :product_review_stat, :tiers, :variant_categories_alive,
    {
      user: [:avatar_attachment, :avatar_blob],
      thumbnail_alive: { file_attachment: { blob: { variant_records: { image_attachment: :blob } } } },
      display_asset_previews: [:file_attachment, :file_blob],
    }
  ]

  attr_reader :product

  def initialize(product:)
    @product = product
  end

  def for_web(request: nil, recommended_by: nil, recommender_model_name: nil, target: nil, show_seller: true, affiliate_id: nil, query: nil, compute_description: true)
    default_recurrence = product.default_price_recurrence
    base_price_cents = product.display_price_cents(for_default_duration: true)
    price_cents = compute_discounted_price_cents(base_price_cents)

    props = {
      id: product.external_id,
      permalink: product.unique_permalink,
      name: product.name,
      seller: show_seller ? UserPresenter.new(user: product.user).author_byline_props(recommended_by:) : nil,
      ratings: product.display_product_reviews? ? {
        count: product.reviews_count,
        average: product.average_rating,
      } : nil,
      thumbnail_url: product.thumbnail_or_cover_url,
      native_type: product.native_type,
      quantity_remaining: product.remaining_for_sale_count,
      is_sales_limited: product.max_purchase_count?,
      price_cents:,
      currency_code: product.price_currency_type.downcase,
      is_pay_what_you_want: product.has_customizable_price_option?,
      url: url_for_product_page(product, request:, recommended_by:, recommender_model_name:, layout: target, affiliate_id:, query:),
      duration_in_months: product.duration_in_months,
      recurrence: default_recurrence&.recurrence,
    }

    # Include base_price_cents when there's a discount to show original price with strikethrough
    if price_cents < base_price_cents
      props[:base_price_cents] = base_price_cents
    end

    if compute_description
      props[:description] = product.plaintext_description.truncate(100)
    end

    props
  end

  private

    def compute_discounted_price_cents(base_price_cents)
      return base_price_cents unless product.default_discount_code.present?

      discount_code_response = OfferCodeDiscountComputingService.new(
        product.default_discount_code.code,
        {
          product.unique_permalink => {
            permalink: product.unique_permalink,
            quantity: [1, product.default_discount_code.minimum_quantity || 0].max
          }
        }
      ).process

      return base_price_cents if discount_code_response[:error_code].present?

      discount = discount_code_response[:products_data][product.unique_permalink]&.dig(:discount)
      return base_price_cents unless discount.present?

      apply_discount_to_price(base_price_cents, discount)
    end

    def apply_discount_to_price(price_cents, discount)
      if discount[:type] == "fixed"
        [price_cents - discount[:cents], 0].max
      elsif discount[:type] == "percent"
        discount_amount = (price_cents * (discount[:percents] / 100.0)).round
        [price_cents - discount_amount, 0].max
      else
        price_cents
      end
    end

  def for_email
    {
      name: product.name,
      thumbnail_url: product.for_email_thumbnail_url,
      url: product.long_url,
      seller: {
        name: product.user.display_name,
        profile_url: product.user.profile_url,
        avatar_url: product.user.avatar_url,
      },
    }
  end
end
