# frozen_string_literal: true

class Products::ManagementController < ApplicationController
  include ProductsHelper, ErrorHandling

  before_action :authenticate_user!
  before_action :fetch_product_and_enforce_ownership, except: [:index, :create]
  after_action :verify_authorized

  def index
    authorize Link

    @products_pagination, @products = paginated_products(page: params[:page] || 1)
    @memberships_pagination, @memberships = paginated_memberships(page: 1)
  end

  def create
    authorize Link

    result = Products::CreationService.call(
      seller: current_seller,
      params: product_params
    )

    if result.success?
      render json: { success: true, product: result[:product] }
    else
      render json: handle_service_error(result)
    end
  end

  def update
    authorize @product

    result = Products::UpdateService.call(
      product: @product,
      params: product_params
    )

    if result.success?
      render json: { success: true, product: result[:product] }
    else
      render json: handle_service_error(result)
    end
  end

  def destroy
    authorize @product

    if @product.can_be_deleted?
      @product.mark_deleted!
      render json: { success: true }
    else
      render json: { success: false, message: "Product cannot be deleted" }
    end
  end

  def publish
    authorize @product

    result = Products::PublishService.call(product: @product)

    if result.success?
      render json: { success: true }
    else
      render json: handle_service_error(result)
    end
  end

  def unpublish
    authorize @product

    @product.update!(published: false)
    render json: { success: true }
  end

  def duplicate
    authorize @product

    result = Products::DuplicationService.call(
      product: @product,
      seller: current_seller
    )

    if result.success?
      render json: { success: true, product: result[:duplicated_product] }
    else
      render json: handle_service_error(result)
    end
  end

  private

  def fetch_product_and_enforce_ownership
    @product = current_seller.products.find_by_external_id(params[:id])
    e404 unless @product
  end

  def product_params
    params.require(:product).permit(
      :name, :description, :price_cents, :summary, :tags,
      :published, :custom_permalink, :content_type
    )
  end

  def paginated_products(page:)
    products = current_seller.products.alive.page(page).per(PER_PAGE)
    pagination_info = {
      current_page: products.current_page,
      total_pages: products.total_pages,
      total_count: products.total_count
    }
    [pagination_info, products]
  end

  def paginated_memberships(page:)
    memberships = current_seller.products.memberships.alive.page(page).per(PER_PAGE)
    pagination_info = {
      current_page: memberships.current_page,
      total_pages: memberships.total_pages,
      total_count: memberships.total_count
    }
    [pagination_info, memberships]
  end
end
