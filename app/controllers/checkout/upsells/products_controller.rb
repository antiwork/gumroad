# frozen_string_literal: true

class Checkout::Upsells::ProductsController < ApplicationController
  include CustomDomainConfig

  MAX_PRODUCTS = 50

  PRODUCT_INCLUDES = [
    :skus_alive_not_default,
    :variant_categories_alive,
    :product_review_stat,
    { alive_variants: { variant_category: :link },
      thumbnail_alive: { file_attachment: { blob: { variant_records: { image_attachment: :blob } } } },
      display_asset_previews: { file_attachment: { blob: { variant_records: { image_attachment: :blob } } } } },
  ].freeze

  def index
    seller = user_by_domain(request.host) || current_seller
    return render json: [] unless seller

    products = seller.products
      .eligible_for_content_upsells
      .includes(*PRODUCT_INCLUDES)
      .order(created_at: :desc, id: :desc)
      .limit(MAX_PRODUCTS)
    render json: products.map { |product| Checkout::Upsells::ProductPresenter.new(product).product_props }
  end

  def show
    product = Link.eligible_for_content_upsells
                  .includes(*PRODUCT_INCLUDES)
                  .find_by_external_id!(params[:id])

    render json: Checkout::Upsells::ProductPresenter.new(product).product_props
  end
end
