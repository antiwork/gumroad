# frozen_string_literal: true

class Products::Edit::ReceiptTabPresenter < Products::Edit::BasePresenter
  def props
    layout_props.merge(product: receipt_tab_product_props)
  end

  # Product hash for the Receipt tab only (receipt-related fields + minimal).
  def receipt_tab_product_props
    full = legacy_presenter.edit_props[:product]
    product_minimal_props.merge(
      full.slice(:custom_receipt_text, :custom_view_content_button_text, :custom_view_content_button_text_max_length)
    )
  end
end
