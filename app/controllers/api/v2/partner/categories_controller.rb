# frozen_string_literal: true

# The category paths the partner product endpoints accept in `category`.
class Api::V2::Partner::CategoriesController < Api::V2::Partner::BaseController
  def index
    expires_in 1.hour
    render json: { success: true, categories: Discover::TaxonomyPresenter.new.categories_for_api }
  end
end
