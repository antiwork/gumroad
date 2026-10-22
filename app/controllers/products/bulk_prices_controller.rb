# frozen_string_literal: true

class Products::BulkPricesController < Sellers::BaseController
  MAX_PRODUCTS = 500

  def create
    authorize Link, :new?

    permalinks = Array(params[:ids]).map(&:to_s).uniq
    return render json: { success: false, error: "Select at least one product." }, status: :unprocessable_entity if permalinks.empty?
    return render json: { success: false, error: "Select at most #{MAX_PRODUCTS} products at a time." }, status: :unprocessable_entity if permalinks.size > MAX_PRODUCTS

    price = params[:price].to_s
    return render json: { success: false, error: "Enter a valid price." }, status: :unprocessable_entity unless price.match?(LinksController::PRICE_INPUT_PATTERN) && price.length <= LinksController::PRICE_INPUT_MAX_LENGTH && !BigDecimal(price).negative?

    results = permalinks.map { |permalink| update_price(permalink, BigDecimal(price)) }
    render json: { success: true, updated: results.count { _1[:updated] }, results: }
  end

  private
    def update_price(permalink, amount)
      product = Link.fetch(permalink, user: current_seller)
      return { id: permalink, updated: false, error: "Product not found." } if product.nil?
      return { id: permalink, updated: false, name: product.name, error: "You can't edit this product." } unless policy(product).update?
      return { id: permalink, updated: false, name: product.name, error: "Tiered memberships are priced per tier." } if product.is_tiered_membership?
      return { id: permalink, updated: false, name: product.name, error: "This product has multiple payment options; edit it in the product editor." } if product.has_multiple_recurrences?

      price_cents = (amount * (product.single_unit_currency? ? 1 : 100)).round
      return { id: permalink, updated: false, name: product.name, error: "Price is too large." } if price_cents > BasePrice::Shared::MAX_PRICE_CENTS

      violation = product.price_range_violation(price_cents)
      return { id: permalink, updated: false, name: product.name, error: "Price is outside the allowed range for this product." } if violation

      product.update!(price_cents:)
      { id: permalink, updated: true, name: product.name }
    rescue Link::LinkInvalid, ActiveRecord::RecordInvalid => e
      { id: permalink, updated: false, name: product&.name, error: e.message }
    end
end
