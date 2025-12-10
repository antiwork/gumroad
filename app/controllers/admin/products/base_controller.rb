# frozen_string_literal: true

class Admin::Products::BaseController < Admin::BaseController
  before_action :set_product

  private
    def set_product
      @product = Link.find_by_external_id!(params[:product_external_id])
    end
end
