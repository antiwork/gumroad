# frozen_string_literal: true

module ProductCardHelpers
  def find_product_card(product)
    page.find(".product-card", text: product.name)
  end

  def expect_product_cards_in_order(products)
    expect(page).to have_product_card(count: products.length)
    products.each_with_index { |product, index| expect(page).to have_selector(".product-card:nth-of-type(#{index + 1})", text: product.name) }
  end

  def expect_product_cards_with_names(*product_names)
    expect(page).to have_product_card(count: product_names.length)
    product_names.each_with_index { |product_name, index| expect(page).to have_selector(".product-card", text: product_name) }
  end
end

module Capybara
  module RSpecMatchers
    def have_product_card(product = nil, **rest)
      have_selector(".product-card header", text: product&.name, **rest)
    end
  end
end
