# frozen_string_literal: true

class Products::BaseController < ApplicationController
  include FetchProductByUniquePermalink

  before_action :authenticate_user!
  before_action :fetch_product_by_unique_permalink
  before_action :authorize_product
  after_action :verify_authorized

  layout "inertia"

  private
    def authorize_product
      authorize @product
    end

    def presenter
      @presenter ||= ProductPresenter.new(product: @product, pundit_user:)
    end
end
