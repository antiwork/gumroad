# frozen_string_literal: true

class Products::AvailableOfferCodesController < Sellers::BaseController
  include FetchProductByUniquePermalink

  MAX_OFFER_CODES_LIMIT = 20

  def index
    fetch_product_by_unique_permalink
    authorize @product, :edit?

    offer_codes = @product.product_and_universal_offer_codes(params[:query], MAX_OFFER_CODES_LIMIT)

    presenter = Products::AvailableOfferCodesPresenter.new(offer_codes:)
    render json: presenter.offer_codes_props
  end
end
