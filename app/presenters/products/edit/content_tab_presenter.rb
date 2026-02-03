# frozen_string_literal: true

class Products::Edit::ContentTabPresenter < Products::Edit::BasePresenter
  def props
    layout_props.merge(product: content_tab_product_props)
  end

  # Product hash for the Content tab only (content-related fields + minimal).
  def content_tab_product_props
    full = legacy_presenter.edit_props[:product]
    product_minimal_props.merge(
      full.slice(:rich_content, :files, :has_same_rich_content_for_all_variants, :variants)
    )
  end
end
