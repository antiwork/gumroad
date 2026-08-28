# frozen_string_literal: true

class Api::Mobile::ProductsController < Api::Mobile::BaseController
  PRODUCTS_PER_PAGE = 20

  before_action { doorkeeper_authorize! :mobile_api }

  def index
    page = [params[:page].to_i, 1].max
    products = current_resource_owner.products.visible.not_archived
    if params[:query].present?
      products = products.where("links.name LIKE ?", "%#{Link.sanitize_sql_like(params[:query])}%")
    end
    products = products.order(created_at: :desc, id: :desc)

    pagination, records = pagy(products, page:, limit: PRODUCTS_PER_PAGE)
    ActiveRecord::Associations::Preloader.new(records:, associations: DashboardProductsPagePresenter::THUMBNAIL_INCLUDES).call

    presenter = DashboardProductsPagePresenter.new(pundit_user: seller_context)
    render json: {
      success: true,
      products: records.map { product_json(_1, presenter) },
      pagination: {
        count: pagination.count,
        page: pagination.page,
        pages: pagination.pages,
        next: pagination.next,
      },
    }
  end

  def destroy
    product = current_resource_owner.products.visible.find_by(unique_permalink: params[:id])
    return fetch_error("Product not found") if product.nil?
    return fetch_error("You cannot delete this product", status: :forbidden) unless Pundit.policy!(seller_context, product).destroy?

    @product = product
    product.delete!
    create_user_event_without_raising("delete_product_mobile_app", user_id: current_resource_owner.id)
    render json: { success: true }
  end

  private
    def seller_context
      SellerContext.new(user: current_resource_owner, seller: current_resource_owner)
    end

    def product_json(product, presenter)
      props = presenter.product_props(product)
      {
        id: product.unique_permalink,
        name: props["name"],
        permalink: props["permalink"],
        price_formatted: props["price_formatted"],
        status: props["status"],
        thumbnail_url: props.dig("thumbnail", "url"),
        can_edit: props["can_edit"],
        can_destroy: props["can_destroy"],
      }
    end
end
