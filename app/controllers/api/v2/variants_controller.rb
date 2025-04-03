# frozen_string_literal: true

class Api::V2::VariantsController < Api::V2::BaseController
  before_action(only: [:index, :show]) { doorkeeper_authorize!(*Doorkeeper.configuration.public_scopes.concat([:view_public])) }
  before_action(only: [:create, :update, :destroy]) { doorkeeper_authorize! :edit_products }
  before_action :fetch_product
  before_action :fetch_variant_category, only: [:index, :create, :show, :update, :destroy]
  before_action :fetch_variant, only: [:show, :update, :destroy]

  def index
    success_with_object(:variants, @variants.alive)
  end

  def create
    variant = Variant.new(permitted_params)
    variant.variant_category = @variant_category
    if variant.save
      success_with_variant(variant)
    else
      error_with_creating_object(:variant, variant)
    end
  end

  def show
    success_with_variant(@variant)
  end

  def update
    if @variant.update(permitted_params)
      success_with_variant(@variant)
    else
      error_with_variant(@variant)
    end
  end

  def destroy
    if @variant.update_attribute(:deleted_at, Time.current)
      success_with_variant
    else
      error_with_variant
    end
  end

  private
    def permitted_params
      params.permit(:price_difference_cents, :description, :name, :max_purchase_count)
    end

    def fetch_variant
      @variant = @variants.find_by_external_id(params[:id])
      error_with_variant(@variant) if @variant.nil?
    end

    def fetch_variant_category
      @variant_category = @product.variant_categories.find_by_external_id(params[:variant_category_id])
      @variants = @variant_category.variants
      error_with_object(:variant_category) if @variant_category.nil?
    end

    def success_with_variant(variant = nil)
      success_with_object(:variant, variant)
    end

    def error_with_variant(variant = nil)
      error_with_object(:variant, variant)
    end
end
