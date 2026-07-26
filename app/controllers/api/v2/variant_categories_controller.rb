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
    # This endpoint is an explicit, single-purpose destructive call and
    # deliberately sits outside the product editor's deletion guards — a caller
    # asked for exactly this. Two things make it worth auditing: it carries no
    # confirmation or revision context at all, and marking a grouping deleted does
    # NOT cascade (VariantCategory's `has_many :variants` has no `dependent:`
    # option), so any live versions stay alive under a deleted grouping.
    #
    # The audit must describe a deletion that this request actually performed.
    # `mark_deleted` succeeds on a row that was already deleted, so two
    # overlapping DELETEs would otherwise both record the same deletion. Claiming
    # the alive -> deleted transition in a single conditional UPDATE makes exactly
    # one request the winner: `update_all` returns the number of rows it changed,
    # and the `deleted_at: nil` predicate means only the first request sees 1.
    alive_child_variant_count = @variant_category.variants.alive.count

    # NOTE: `variant_categories` has no `updated_at` column (see db/schema.rb), so
    # only `deleted_at` is written here. `base_variants` does have one, which is
    # why the single-variant destroy sets both.
    claimed = VariantCategory.where(id: @variant_category.id, deleted_at: nil)
                             .update_all(deleted_at: Time.current)

    if claimed.zero?
      # Either already deleted, or a concurrent request won the race. Reload so
      # the response reflects committed state, and record nothing: the deletion
      # this request would have described was not performed by this request.
      @variant_category.reload
      return success_with_variant_category
    end

    @variant_category.reload
    ProductVariantDeletionAudit.record_deletion(
      actor_user_id: current_resource_owner&.id,
      product_id: @product.id,
      route: ProductVariantDeletionAudit::API_V2_VARIANT_CATEGORY_DESTROY,
      deleted_variant_category_external_ids: [@variant_category.external_id],
      intent_source: ProductVariantDeletionAudit::API_EXPLICIT_DESTROY,
      alive_child_variant_count:,
      correlation_id: AuditCorrelationId.log_for(request.request_id),
    )
    success_with_variant_category
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
