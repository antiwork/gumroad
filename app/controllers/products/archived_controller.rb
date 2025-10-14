# frozen_string_literal: true

class Products::ArchivedController < Sellers::BaseController
  include ProductsHelper

  PER_PAGE = 50

  before_action :fetch_product_and_enforce_ownership, only: %i[create destroy]

  layout "inertia", only: [:index]

  def index
    authorize [:products, :archived, Link]

    memberships_pagination, memberships = paginated_memberships(page: 1)
    products_pagination, products = paginated_products(page: 1)

    return redirect_to products_url if memberships.none? && products.none?

    props = DashboardProductsPagePresenter.new(
      pundit_user:,
      memberships:,
      memberships_pagination:,
      products:,
      products_pagination:
    ).page_props

    @title = "Archived products"

    render inertia: "Products/Archived/Index", props:
  end

  def products_paged
    authorize [:products, :archived, Link], :index?

    products_pagination, products = paginated_products(page: params[:page].to_i, query: params[:query])

    react_products_page_props = DashboardProductsPagePresenter.new(
      pundit_user:,
      products:,
      products_pagination:,
      memberships: nil,
      memberships_pagination: nil
    ).products_table_props

    render json: {
      pagination: react_products_page_props[:products_pagination],
      entries: react_products_page_props[:products]
    }
  end

  def memberships_paged
    authorize [:products, :archived, Link], :index?

    memberships_pagination, memberships = paginated_memberships(page: paged_params[:page].to_i, query: params[:query])

    react_products_page_props = DashboardProductsPagePresenter.new(
      pundit_user:,
      products: nil,
      products_pagination: nil,
      memberships:,
      memberships_pagination:
    ).memberships_table_props

    render json: {
      pagination: react_products_page_props[:memberships_pagination],
      entries: react_products_page_props[:memberships]
    }
  end

  def create
    authorize [:products, :archived, @product]

    @product.update!(archived: true)
    render json: { success: true }
  end

  def destroy
    authorize [:products, :archived, @product]

    @product.update!(archived: false)
    render json: { success: true, archived_products_count: current_seller.archived_products_count }
  end

  private
    def paged_params
      params.permit(:page, sort: [:key, :direction])
    end

    def paginated_memberships(page:, query: nil)
      memberships = current_seller.products.membership.visible.archived
      memberships = memberships.where("name like ?", "%#{query}%") if query.present?

      sort_and_paginate_products(**paged_params[:sort].to_h.symbolize_keys, page:, collection: memberships, per_page: PER_PAGE, user_id: current_seller.id)
    end

    def paginated_products(page:, query: nil)
      products = current_seller.products.non_membership.visible.archived
      products = products.where("name like ?", "%#{query}%") if query.present?

      sort_and_paginate_products(**paged_params[:sort].to_h.symbolize_keys, page:, collection: products, per_page: PER_PAGE, user_id: current_seller.id)
    end
end
