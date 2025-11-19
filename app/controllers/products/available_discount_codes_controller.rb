# frozen_string_literal: true

class Products::AvailableDiscountCodesController < Sellers::BaseController
  include FetchProductByUniquePermalink

  def index
    fetch_product_by_unique_permalink
    authorize @product, :edit?

    offer_codes = @product.product_and_universal_offer_codes

    if params[:query].present?
      query = params[:query].to_s.strip.downcase
      offer_codes = offer_codes.select do |offer_code|
        [offer_code.name, offer_code.code].compact.any? { _1.downcase.include?(query) }
      end
    end

    offer_codes = offer_codes.first(20)

    render json: offer_codes.map { |offer_code| serialize_offer_code(offer_code) }
  end

  private
    def serialize_offer_code(offer_code)
      {
        id: offer_code.external_id,
        code: offer_code.code,
        name: offer_code.name.presence || "",
        discount: offer_code.discount,
      }
    end
end
