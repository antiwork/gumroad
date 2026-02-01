# frozen_string_literal: true

class Products::ReceiptController < Products::BaseController
  def edit
    set_meta_tag(title: @product.name)

    render inertia: "Products/Receipt/Edit", props: presenter.edit_receipt_props
  end

  def update
    @product.update!(receipt_permitted_params)

    redirect_back fallback_location: edit_product_receipt_path(@product.external_id),
                  notice: "Changes saved!",
                  status: :see_other
  rescue ActiveRecord::RecordNotSaved, ActiveRecord::RecordInvalid => e
    error_message = @product.errors.full_messages.first || e.message
    redirect_to edit_product_receipt_path(@product.external_id), alert: error_message, inertia: inertia_errors(@product)
  end

  private
    def receipt_permitted_params
      params.permit(
        :custom_view_content_button_text,
        :custom_receipt_text
      )
    end
end
