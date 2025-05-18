# frozen_string_literal: true

class Admin::Products::StaffPickedController < Admin::BaseController
  include AfterCommitEverywhere

  before_action :set_product

  def create
    authorize [:admin, :products, :staff_picked, @product]

    staff_picked_product = @product.staff_picked_product || @product.build_staff_picked_product
    staff_picked_product.update_as_not_deleted!

    render json: { success: true }
  end

  private
    def set_product
      @product = Link.find(params[:product_id])
    end
end
