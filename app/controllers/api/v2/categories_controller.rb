# frozen_string_literal: true

class Api::V2::CategoriesController < Api::V2::BaseController
  before_action -> { doorkeeper_authorize!(*Doorkeeper.configuration.public_scopes.concat([:view_public])) }

  def index
    render json: {
      success: true,
      categories: Discover::TaxonomyPresenter.new.categories_for_api
    }
  end
end
