# frozen_string_literal: true

class Products::UpdateService < ApplicationService
  attr_reader :product, :params

  def initialize(product:, params:)
    @product = product
    @params = params
  end

  private

  def perform
    if product.update(filtered_params)
      success(product: product)
    else
      failure("Failed to update product", errors: product.errors.as_json)
    end
  end

  def filtered_params
    permitted_params = params.slice(
      :name, :description, :price_cents, :summary, :tags,
      :published, :custom_permalink, :content_type
    )

    permitted_params.compact
  end

  def service_context
    {
      product_id: product.id,
      update_params: params
    }
  end
end
