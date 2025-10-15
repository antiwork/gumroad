# frozen_string_literal: true

class Products::CollabsController < Sellers::BaseController
  before_action :authorize

  layout "inertia", only: [:index]

  def index
    @title = "Products"
    props = CollabProductsPagePresenter.new(**presenter_params).initial_page_props

    respond_to do |format|
      format.html { render inertia: "Products/Collabs/Index", props: }
      format.json { render json: props }
    end
  end

  def memberships_paged
    props = CollabProductsPagePresenter.new(**presenter_params).memberships_table_props

    render json: {
      pagination: props[:memberships_pagination],
      entries: props[:memberships],
    }
  end

  def products_paged
    props = CollabProductsPagePresenter.new(**presenter_params).products_table_props

    render json: {
      pagination: props[:products_pagination],
      entries: props[:products],
    }
  end

  private
    def authorize
      super([:products, :collabs])
    end

    def presenter_params
      permitted_params = params.permit(:page, :query, sort: [:key, :direction])

      {
        pundit_user:,
        page: permitted_params[:page].to_i,
        sort_params: permitted_params[:sort],
        query: permitted_params[:query],
      }
    end
end
