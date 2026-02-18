# frozen_string_literal: true

class Products::ReceiptTabController < Products::BaseTabController
  def edit
    set_meta_tag(title: @product.name)
    render inertia: "Products/Edit/ReceiptTab", props: presenter.edit_props
  end

  def update
    handle_update do
      @product.assign_attributes(receipt_tab_params)
      @product.save_custom_button_text_option(params[:link][:custom_button_text_option]) if params[:link][:custom_button_text_option]
      @product.save!
    end
  end

  private

    def receipt_tab_params
      params.require(:link).permit(
        :custom_receipt_text,
        :custom_view_content_button_text,
        :lock_version
      )
    end
end
