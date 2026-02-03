# frozen_string_literal: true

class Products::Edit::ShareTabPresenter < Products::Edit::BasePresenter
  def props
    layout_props.merge(product: share_tab_product_props)
  end

  # Product hash for the Share tab only (share-related fields + minimal).
  def share_tab_product_props
    full = legacy_presenter.edit_props[:product]
    product_minimal_props.merge(
      full.slice(:tags, :taxonomy_id, :display_product_reviews, :is_adult, :custom_domain, :section_ids, :collaborating_user)
    )
  end
end
