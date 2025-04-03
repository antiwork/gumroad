# frozen_string_literal: true

class Products::VariantsController < Sellers::BaseController
  def index
    fetch_product_and_enforce_ownership
    authorize [:products, :variants, @product]

    render json: @product.options
  end
end
