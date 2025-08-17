# frozen_string_literal: true

class Products::DuplicationService < ApplicationService
  attr_reader :product, :seller

  def initialize(product:, seller:)
    @product = product
    @seller = seller
  end

  private

  def perform
    duplicated_product = ProductDuplicatorService.new(product).duplicate

    if duplicated_product.persisted?
      success(duplicated_product: duplicated_product)
    else
      failure("Failed to duplicate product", errors: duplicated_product.errors.as_json)
    end
  end

  def service_context
    {
      original_product_id: product.id,
      seller_id: seller.id
    }
  end
end
