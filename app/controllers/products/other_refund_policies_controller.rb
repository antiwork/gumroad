# frozen_string_literal: true

class Products::OtherRefundPoliciesController < Sellers::BaseController
  include FetchProductByUniquePermalink

  def index
    fetch_product_by_unique_permalink
    authorize @product, :edit?

    product_refund_policies = @product.user
      .product_refund_policies
      .for_visible_and_not_archived_products
      .where.not(product_id: @product.id)
      .order(updated_at: :desc)
      .select("refund_policies.*", "links.name")

    render json: product_refund_policies
  end
end
