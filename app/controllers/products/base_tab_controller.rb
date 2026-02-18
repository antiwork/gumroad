# frozen_string_literal: true

class Products::BaseTabController < ApplicationController
  include FetchProductByUniquePermalink

  before_action :authenticate_user!
  before_action :fetch_product_by_unique_permalink
  before_action :authorize_product

  layout "inertia"

  private

    def authorize_product
      authorize @product
    end

    def presenter
      @presenter ||= ProductPresenter.new(
        product: @product,
        pundit_user:,
        ai_generated: params[:ai_generated] == "true"
      )
    end

    def handle_update
      authorize @product
      ActiveRecord::Base.transaction do
        yield
      end
      render json: { success: true }
    rescue ActiveRecord::StaleObjectError
      render json: {
        error: "conflict",
        message: "This product was modified elsewhere. Please refresh."
      }, status: :conflict
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
      render json: { error: e.message }, status: :unprocessable_entity
    end
end
