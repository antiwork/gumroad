# frozen_string_literal: true

class Products::BaseController < ApplicationController
  before_action :authenticate_user!
  before_action :fetch_product
  before_action :authorize_product
  after_action :verify_authorized

  layout "inertia"

  private
    def fetch_product
      external_id = params[:product_id] || params[:id]
      @product = Link.find_by_external_id(external_id) || e404
    end

    def authorize_product
      authorize @product
    end

    def presenter
      @presenter ||= ProductPresenter.new(product: @product, pundit_user:)
    end
end
