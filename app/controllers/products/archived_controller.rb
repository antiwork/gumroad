# frozen_string_literal: true

class Products::ArchivedController < Sellers::BaseController
  include ProductsHelper

  before_action :fetch_product_and_enforce_ownership, only: %i[create destroy]

  layout "inertia", only: [:index]

  def index
    authorize [:products, :archived, Link]

    return redirect_to products_url if archived_products_page_presenter.empty?

    set_meta_tag(title: "Archived products")

    render inertia: "Products/Archived/Index", props: {
      can_create_product: -> { archived_products_page_presenter.page_props[:can_create_product] },
      products_data: -> {
        {
          products: archived_products_page_presenter.products_table_props[:products],
          pagination: archived_products_page_presenter.products_table_props[:products_pagination],
          sort: archived_products_page_presenter.products_sort,
        }
      },
      memberships_data: -> {
        {
          memberships: archived_products_page_presenter.memberships_table_props[:memberships],
          pagination: archived_products_page_presenter.memberships_table_props[:memberships_pagination],
          sort: archived_products_page_presenter.memberships_sort,
        }
      },
    }
  end

  def create
    authorize [:products, :archived, @product]

    @product.update!(
      archived: true,
      purchase_disabled_at: @product.purchase_disabled_at || Time.current
    )

    render json: { success: true }
  end

  def destroy
    authorize [:products, :archived, @product]

    @product.update!(archived: false)
    render json: { success: true, archived_products_count: current_seller.archived_products_count }
  end

  private
    def archived_products_page_presenter
      @archived_products_page_presenter ||= DashboardProductsPagePresenter.new(
        pundit_user:,
        archived: true,
        query: index_params[:query],
        products_page: index_params[:products_page],
        products_sort: index_params[:products_sort],
        memberships_page: index_params[:memberships_page],
        memberships_sort: index_params[:memberships_sort]
      )
    end

    def index_params
      @index_params ||= begin
        permitted = params.permit(
          :query, :products_page, :memberships_page,
          :products_sort_key, :products_sort_direction,
          :memberships_sort_key, :memberships_sort_direction
        )

        {
          query: permitted[:query],
          products_page: permitted[:products_page],
          products_sort: extract_sort_params(:products, permitted),
          memberships_page: permitted[:memberships_page],
          memberships_sort: extract_sort_params(:memberships, permitted)
        }
      end
    end

    def extract_sort_params(prefix, permitted)
      key = permitted[:"#{prefix}_sort_key"]
      direction = permitted[:"#{prefix}_sort_direction"]
      return nil unless %w[name display_price_cents successful_sales_count revenue status].include?(key)
      { key:, direction: direction == "desc" ? "desc" : "asc" }
    end
end
