# frozen_string_literal: true

class Products::AvailableDiscountCodesController < Sellers::BaseController
  include FetchProductByUniquePermalink

  MAX_OFFER_CODES_LIMIT = 20

  def index
    fetch_product_by_unique_permalink
    authorize @product, :edit?

    offer_codes = @product.product_and_universal_offer_codes

    if params[:query].present?
      query = params[:query].to_s.strip.downcase
      # Note: We are searching in an array here which could become a potential bottleneck.
      # But we can keep the existing code until it becomes a problem.
      offer_codes = offer_codes.select do |offer_code|
        [offer_code.name, offer_code.code].compact.any? { _1.downcase.include?(query) }
      end
    end

    offer_codes = offer_codes.first(MAX_OFFER_CODES_LIMIT)

    presenter = Products::AvailableDiscountCodesPresenter.new(offer_codes:)
    render json: presenter.offer_codes_props
  end
end
