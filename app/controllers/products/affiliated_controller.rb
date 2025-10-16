# frozen_string_literal: true

class Products::AffiliatedController < Sellers::BaseController
  before_action :authorize

  layout "inertia", only: [:index]

  def index
    @title = "Products"
    props = AffiliatedProductsPresenter.new(current_seller,
                                            query: affiliated_products_params[:query],
                                            page: affiliated_products_params[:page],
                                            sort: affiliated_products_params[:sort])
                                       .affiliated_products_page_props
    respond_to do |format|
      format.html { render inertia: "Products/Affiliated/Index", props: }
      format.json { render json: props }
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
