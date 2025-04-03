# frozen_string_literal: true

class Api::V2::VariantCategoriesController < Api::V2::BaseController
  before_action(only: [:index, :show]) { doorkeeper_authorize!(*Doorkeeper.configuration.public_scopes.concat([:view_public])) }
  before_action(only: [:create, :update, :destroy]) { doorkeeper_authorize! :edit_products }
  before_action :fetch_product
  before_action :fetch_variant_category, only: [:show, :update, :destroy]

  def index
    success_with_object(:variant_categories, @product.variant_categories.alive)
  end

  def create
    variant_category = VariantCategory.create(permitted_params.merge(link_id: @product.id))
    success_with_variant_category(variant_category)
  end

  def show
    success_with_variant_category(@variant_category)
  end

  def update
    if @variant_category.update(permitted_params)
      success_with_variant_category(@variant_category)
    else
      error_with_variant_category(@variant_category)
    end
  end

  def destroy
    if @variant_category.mark_deleted
      success_with_variant_category
    else
      error_with_variant_category(@variant_category)
    end
  end

  private
    def permitted_params
      params.permit(:title)
    end

    def fetch_variant_category
      @variant_category = @product.variant_categories.find_by_external_id(params[:id])
      error_with_variant_category if @variant_category.nil?
    end

    def success_with_variant_category(variant_category = nil)
      success_with_object(:variant_category, variant_category)
    end

    def error_with_variant_category(variant_category = nil)
      error_with_object(:variant_category, variant_category)
    end
end
