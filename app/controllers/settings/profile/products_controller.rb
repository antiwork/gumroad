# frozen_string_literal: true

class Settings::Profile::ProductsController < ApplicationController
  def show
    product = current_seller.products.find_by_external_id!(params[:id])
    authorize product

    # Avoid passing the pundit_user so that the product renders as non-editable
    render json: ProductPresenter.new(product:, request:).product_props(seller_custom_domain_url:)
  end
end
