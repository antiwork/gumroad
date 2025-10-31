# frozen_string_literal: true

class Admin::Products::StaffPickedController < Admin::Products::BaseController
  include AfterCommitEverywhere

  def create
    authorize [:admin, :products, :staff_picked, @product]

    staff_picked_product = @product.staff_picked_product || @product.build_staff_picked_product
    staff_picked_product.update_as_not_deleted!

    render json: { success: true }
  end
end
