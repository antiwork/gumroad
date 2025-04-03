# frozen_string_literal: true

class Api::Internal::ProductPostsController < Api::Internal::BaseController
  include FetchProductByUniquePermalink

  before_action :authenticate_user!
  before_action :fetch_product_by_unique_permalink, only: :index

  def index
    e404 if @product.user != current_seller

    render json: PaginatedProductPostsPresenter.new(product: @product, variant_external_id: params[:variant_id], options: { page: params[:page] }).index_props
  end
end
