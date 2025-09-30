# frozen_string_literal: true

class Products::AffiliatedController < Sellers::BaseController
  before_action :authorize

  def index
    @title = "Products"
    props = AffiliatedProductsPresenter.new(current_seller,
                                           query: affiliated_products_params[:query],
                                           page: affiliated_products_params[:page],
                                           sort: affiliated_products_params[:sort])
                                      .affiliated_products_page_props

    if request.format.json?
      render json: props
    else
      render inertia: "Products/Affiliated/index", props: inertia_props(**props)
    end
  end

  private
    def authorize
      super([:products, :affiliated])
    end

    def affiliated_products_params
      params.permit(:query, :page, sort: [:key, :direction])
    end
end
