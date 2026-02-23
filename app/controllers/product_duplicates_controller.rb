# frozen_string_literal: true

class ProductDuplicatesController < Sellers::BaseController
  before_action :fetch_product_and_enforce_ownership

  def create
    authorize [:product_duplicates, @product]

    if @product.is_duplicating
      render(json: { success: false, error_message: "Duplication in progress..." }) && (return)
    end

    DuplicateProductWorker.perform_async(@product.id)
    @product.is_duplicating = true
    # Skip validations because products may have update-only validation errors (e.g. call products
    # without durations) unrelated to toggling this flag.
    @product.save!(validate: false)

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
      error_message = ProductDuplicatorService.new(@product.id).recently_failed_error_message
      render(json: { success: false, status: ProductDuplicatorService::DUPLICATION_FAILED, error_message: }) && return
    end

    is_membership = duplicated_product.is_recurring_billing?
    presenter = DashboardProductsPagePresenter.new(pundit_user:)
    duplicated_product = presenter.product_props(duplicated_product)

    render json: {
      success: true,
      status: ProductDuplicatorService::DUPLICATED,
      product: @product,
      duplicated_product:,
      is_membership:
    }
  end
end
