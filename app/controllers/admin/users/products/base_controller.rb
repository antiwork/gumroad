# frozen_string_literal: true

class Admin::Users::Products::BaseController < Admin::Users::BaseController
  before_action :fetch_user
  before_action :set_product

  private
    def set_product
      @product = Link.find(params[:product_id])
    end
end
