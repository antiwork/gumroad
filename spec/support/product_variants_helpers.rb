# frozen_string_literal: true

# Helper methods for the versions/variants part of the product edit page
module ProductVariantsHelpers
  def version_rows
    all("[aria-label='Version editor']")
  end

  def version_option_rows
    all("[role=listitem]")
  end

  def within_content_tab_section(section_name, &block)
    within "main", match: :first do
      within_section section_name, section_element: :section, &block
    end
  end

  def be_selected_for_option
    have_checked_field "Add file to option"
  end

  def remove_version_option
    click_on "Remove version"
  end

  def variant_rows
    all(".variants-box")
  end

  def sku_rows
    all(".sku-row")
  end

  def offer_code_rows
    all(".discount-code-row")
  end

  def tier_rows
    all("[role=list][aria-label='Tier editor'] [role=listitem]")
  end
end
