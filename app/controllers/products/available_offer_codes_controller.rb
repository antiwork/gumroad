# frozen_string_literal: true

class Products::AvailableOfferCodesController < Sellers::BaseController
  include FetchProductByUniquePermalink

  MAX_OFFER_CODES_LIMIT = 20
  INITIAL_OFFER_CODES_LIMIT = 5

  def index
    fetch_product_by_unique_permalink
    authorize @product, :edit?

    limit = params[:query].present? ? MAX_OFFER_CODES_LIMIT : INITIAL_OFFER_CODES_LIMIT
    # New-customer codes cannot be a product's default (see Link#default_offer_code_must_be_valid).
    offer_codes = @product.product_and_universal_offer_codes(params[:query], limit, true, exclude_new_customers_only: true)

    presenter = Products::AvailableOfferCodesPresenter.new(offer_codes:)
    render json: presenter.offer_codes_props
  end
end
