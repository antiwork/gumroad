# frozen_string_literal: true

class Products::Edit::ReceiptController < Products::BaseController
  def show
    props = presenter.edit_props

    render inertia: "Products/Edit/Receipt", props:
  end

  def update
    authorize @product

    ActiveRecord::Base.transaction do
      @product.assign_attributes(receipt_permitted_params)
      @product.save!
    end

    redirect_back fallback_location: product_edit_receipt_path(@product.unique_permalink), notice: "Changes saved!", status: :see_other
  rescue ActiveRecord::RecordNotSaved, ActiveRecord::RecordInvalid, Link::LinkInvalid => e
    error_message = @product.errors.full_messages.first || e.message
    redirect_to product_edit_receipt_path(@product.unique_permalink), alert: error_message
  end

  private
    def receipt_permitted_params
      params.permit(
        :custom_view_content_button_text,
        :custom_receipt_text
      )
    end
end
