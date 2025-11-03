# frozen_string_literal: true

class Admin::Products::DetailsController < Admin::Products::BaseController
  def show
    if @product.filegroup
      render json: { details: ProductPresenter.new(product: @product).admin_info }
    else
      render json: { details: nil }
    end
  end
end
