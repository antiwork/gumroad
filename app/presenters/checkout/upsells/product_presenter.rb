# frozen_string_literal: true

class Checkout::Upsells::ProductPresenter
  def initialize(product)
    @product = product
  end

  def product_props
    {
      id: product.external_id,
      permalink: product.unique_permalink,
      name: product.name,
      price_cents: product.price_cents,
      currency_code: product.price_currency_type.downcase,
      review_count: product.reviews_count,
      average_rating: product.average_rating,
      native_type: product.native_type,
      thumbnail_url: product.thumbnail_or_cover_url,
      options: product.options
    }
  end

  private
    attr_reader :product
end
