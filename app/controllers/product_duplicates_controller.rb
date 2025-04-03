# frozen_string_literal: true

class ProductDuplicatesController < Sellers::BaseController
  before_action :fetch_product_and_enforce_ownership

  def create
    authorize [:product_duplicates, @product]

    if @product.is_duplicating
      render(json: { success: false, error_message: "Duplication in progress..." }) && (return)
    end

    DuplicateProductWorker.perform_async(@product.id)
    @product.update!(is_duplicating: true)

    render json: { success: true }
  end

  def show
    authorize [:product_duplicates, @product]

    if @product.is_duplicating
      render(json: { success: false, status: ProductDuplicatorService::DUPLICATING, error_message: "Duplication in progress..." }) && return
    end

    duplicated_product = ProductDuplicatorService.new(@product.id).recently_duplicated_product

    unless duplicated_product
      # Product is not duplicating and we can't find it in redis
      render(json: { success: false, status: ProductDuplicatorService::DUPLICATION_FAILED }) && return
    end

    if duplicated_product.is_recurring_billing?
      page_props = DashboardProductsPagePresenter.new(
        pundit_user:,
        memberships: [duplicated_product],
        memberships_pagination: nil,
        products: [],
        products_pagination: nil
      ).page_props
      duplicated_product = page_props[:memberships].first
      is_membership = true
    else
      page_props = DashboardProductsPagePresenter.new(
        pundit_user:,
        memberships: [],
        memberships_pagination: nil,
        products: [duplicated_product],
        products_pagination: nil
      ).page_props
      duplicated_product = page_props[:products].first
      is_membership = false
    end

    render json: {
      success: true,
      status: ProductDuplicatorService::DUPLICATED,
      product: @product,
      duplicated_product:,
      is_membership:
    }
  end
end
