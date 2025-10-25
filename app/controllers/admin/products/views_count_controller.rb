# frozen_string_literal: true

class Admin::Products::ViewsCountController < Admin::Products::BaseController
  def show
    render json: { views_count: @product.views_count }
  end
end
