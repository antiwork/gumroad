# frozen_string_literal: true

class Api::Internal::ExistingProductFilesController < Api::Internal::BaseController
  include FetchProductByUniquePermalink

  before_action :authenticate_user!
  before_action :fetch_product_by_unique_permalink, only: :index

  def index
    e404 if @product.user != current_seller

    render json: { existing_files: ProductPresenter.new(product: @product, pundit_user:).existing_files }
  end
end
