# frozen_string_literal: true

class Iffy::Product::FlagService
  attr_reader :product

  def initialize(product_id)
    @product = Link.find_by_external_id!(product_id)
  end

  def perform
    product.unpublish!(is_unpublished_by_admin: true)
  end
end
