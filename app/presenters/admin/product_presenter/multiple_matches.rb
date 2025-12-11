# frozen_string_literal: true

class Admin::ProductPresenter::MultipleMatches
  attr_reader :product

  def initialize(product:)
    @product = product
  end

  def props
    {
      id: product.id,
      name: product.name,
      created_at: product.created_at,
      long_url: product.long_url,
      price_formatted: product.price_formatted,
      user: {
        id: product.user.id,
        name: product.user.name
      }
    }
  end
end
