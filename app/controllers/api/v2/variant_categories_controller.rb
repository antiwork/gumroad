# frozen_string_literal: true

class Api::V2::VariantCategoriesController < Api::V2::BaseController
  before_action(only: [:index, :show]) { doorkeeper_authorize!(*Doorkeeper.configuration.public_api_read_scopes.concat([:view_public])) }
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
    # Captured before the deletion: afterwards the category is gone and the
    # count would be harder to attribute to this request.
    alive_child_variant_count = @variant_category.variants.alive.count

    if @variant_category.mark_deleted
      # This endpoint is an explicit, single-purpose destructive call and
      # deliberately sits outside the product editor's deletion guards — a
      # caller asked for exactly this. Two things make it worth recording:
      # it carries no confirmation or revision context at all, and
      # `mark_deleted` does NOT cascade (VariantCategory's `has_many :variants`
      # has no `dependent:` option), so any live versions stay alive under a
      # deleted grouping. `alive_child_variant_count` makes that visible.
      ProductVariantDeletionAudit.record_deletion(
        actor_user_id: current_resource_owner&.id,
        link_id: @product.id,
        route: ProductVariantDeletionAudit::API_V2_VARIANT_CATEGORY_DESTROY,
        deleted_variant_category_external_ids: [@variant_category.external_id],
        intent_source: ProductVariantDeletionAudit::API_EXPLICIT_DESTROY,
        alive_child_variant_count:,
        request_id: request.request_id,
      )
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
