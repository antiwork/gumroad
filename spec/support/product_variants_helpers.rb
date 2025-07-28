# frozen_string_literal: true

# Helper methods for the versions/variants part of the product edit page
module ProductVariantsHelpers
  def version_rows
    all("[aria-label='Version editor']")
  end

  def version_option_rows
    all("[role=listitem]")
  end

  def remove_version_option
    click_on "Remove version"
  end

  def tier_rows
    all("[role=list][aria-label='Tier editor'] [role=listitem]")
  end
end
