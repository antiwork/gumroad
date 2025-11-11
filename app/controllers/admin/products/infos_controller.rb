# frozen_string_literal: true

class Admin::Products::InfosController < Admin::Products::BaseController
  def show
    render json: { info: @product.as_json(admin_info: true) }
  end
end
