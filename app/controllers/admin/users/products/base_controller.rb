# frozen_string_literal: true

class Admin::Users::Products::BaseController < Admin::Users::BaseController
  before_action :fetch_user
  before_action :set_product

  private
    def set_product
      @product = Link.find_by_external_id!(params[:product_external_id])
    end
end
