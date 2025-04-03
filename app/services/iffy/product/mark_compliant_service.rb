# frozen_string_literal: true

class Iffy::Product::MarkCompliantService
  attr_reader :product

  def initialize(product_id)
    @product = Link.find_by_external_id!(product_id)
  end

  def perform
    product.update!(is_unpublished_by_admin: false)
    product.publish!
  end
end
