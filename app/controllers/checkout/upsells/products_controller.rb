# frozen_string_literal: true

class Checkout::Upsells::ProductsController < ApplicationController
  include CustomDomainConfig

  def index
    seller = user_by_domain(request.host) || current_seller
    render json: seller.products.eligible_for_content_upsells.map { |product| Checkout::Upsells::ProductPresenter.new(product).product_props }
  end

  def show
    product = Link.eligible_for_content_upsells
                  .find_by_external_id!(params[:id])

    render json: Checkout::Upsells::ProductPresenter.new(product).product_props
  end
end
