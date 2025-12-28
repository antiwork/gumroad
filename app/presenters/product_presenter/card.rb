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

  def for_web(request: nil, recommended_by: nil, recommender_model_name: nil, target: nil, show_seller: true, affiliate_id: nil, query: nil, offer_code: nil, compute_description: true)
    default_recurrence = product.default_price_recurrence
    original_price_cents = product.display_price_cents(for_default_duration: true)

    # Determine effective offer code: URL code takes priority over default
    effective_offer_code = if offer_code.present?
      product.find_offer_code(code: offer_code)
    else
      product.effective_default_offer_code
    end
    is_default_discount = offer_code.blank? && effective_offer_code.present?

    # Calculate discounted price if offer code is valid
    discounted_price_cents = if effective_offer_code
      original_price_cents - effective_offer_code.amount_off(original_price_cents)
    else
      original_price_cents
    end

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
      price_cents: discounted_price_cents,
      original_price_cents: effective_offer_code ? original_price_cents : nil,
      currency_code: product.price_currency_type.downcase,
      is_pay_what_you_want: product.has_customizable_price_option?,
      url: url_for_product_page(product, request:, recommended_by:, recommender_model_name:, layout: target, affiliate_id:, query:, offer_code:),
      duration_in_months: product.duration_in_months,
      recurrence: default_recurrence&.recurrence,
    }

    # Add discount badge info if an offer code is applied
    if effective_offer_code
      props[:discount_badge] = {
        code: effective_offer_code.code,
        percent_off: effective_offer_code.is_percent? ? effective_offer_code.amount_percentage : nil,
        amount_off_cents: effective_offer_code.is_cents? ? effective_offer_code.amount_cents : nil,
        is_default: is_default_discount,
      }
    end

    if compute_description
      props[:description] = product.plaintext_description.truncate(100)
    end

    props
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
