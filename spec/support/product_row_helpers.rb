# frozen_string_literal: true

module ProductRowHelpers
  def find_product_row(product)
    find("[role=listitem]", text: product.name)
  end

  def drag_product_row(product, to:)
    product_row = find_product_row(product)
    to_product_row = find_product_row(to)
    within product_row do
      find("[aria-grabbed]").drag_to to_product_row
    end
  end
end
