# frozen_string_literal: true

class Products::CreationService < ApplicationService
  attr_reader :seller, :params

  def initialize(seller:, params:)
    @seller = seller
    @params = params
  end

  private

  def perform
    validate_seller_can_create_product!

    product = build_product

    if product.save
      success(product: product)
    else
      failure("Failed to create product", errors: product.errors.as_json)
    end
  end

  def validate_seller_can_create_product!
    unless seller.can_create_products?
      raise StandardError, "Seller cannot create products"
    end
  end

  def build_product
    seller.products.build(product_attributes)
  end

  def product_attributes
    {
      name: params[:name] || "Untitled Product",
      description: params[:description],
      price_cents: params[:price_cents] || 0,
      summary: params[:summary],
      tags: params[:tags],
      published: false,
      custom_permalink: params[:custom_permalink],
      content_type: params[:content_type] || "digital"
    }
  end

  def service_context
    {
      seller_id: seller.id,
      product_params: params
    }
  end
end
