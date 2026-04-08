# frozen_string_literal: true

class Checkout::Upsells::ProductsController < ApplicationController
  include CustomDomainConfig

  MAX_PRODUCTS = 50

  def index
    seller = user_by_domain(request.host) || current_seller
    products = seller.products
      .eligible_for_content_upsells
      .includes(
        thumbnail_alive: { file_attachment: { blob: { variant_records: { image_attachment: :blob } } } },
        display_asset_previews: { file_attachment: { blob: { variant_records: { image_attachment: :blob } } } }
      )
      .order(created_at: :desc, id: :desc)
      .limit(MAX_PRODUCTS)
    render json: products.map { |product| Checkout::Upsells::ProductPresenter.new(product).product_props }
  end

  def show
    product = Link.eligible_for_content_upsells
                  .find_by_external_id!(params[:id])

    render json: Checkout::Upsells::ProductPresenter.new(product).product_props
  end
end
