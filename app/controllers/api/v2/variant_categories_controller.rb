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
    # The audit must describe a deletion this request actually performed, so a
    # retry must not add a second row for one deletion. Getting that right without
    # changing behaviour rules out `update_all`: it would skip
    # `after_commit :invalidate_product_cache`, leaving stale product caches.
    #
    # So take a row lock, re-read `deleted_at` inside it, and go through the
    # model's own `mark_deleted` exactly as before. The lock serialises concurrent
    # DELETEs, and re-reading under it means the loser sees the winner's committed
    # deletion and records nothing.
    #
    # `deletion_failed` is carried out of the block rather than returned from
    # inside it: returning from a transaction block is its own subtle hazard, so
    # the response is chosen after the transaction closes.
    deletion_failed = false

    @variant_category.with_lock do
      # Re-read under the lock: `@variant_category` was loaded before it.
      unless @variant_category.reload.deleted?
        alive_child_variant_count = @variant_category.variants.alive.count

        if @variant_category.mark_deleted
          # Scheduled inside the same transaction as the deletion, so the audit and
          # the deletion commit together or not at all.
          ProductVariantDeletionAudit.record_deletion(
            actor_user_id: current_resource_owner&.id,
            product_id: @product.id,
            route: ProductVariantDeletionAudit::API_V2_VARIANT_CATEGORY_DESTROY,
            deleted_variant_category_external_ids: [@variant_category.external_id],
            intent_source: ProductVariantDeletionAudit::API_EXPLICIT_DESTROY,
            alive_child_variant_count:,
            correlation_id: AuditCorrelationId.log_for(request.request_id),
          )
        else
          deletion_failed = true
        end
      end
    end

    return error_with_variant_category(@variant_category) if deletion_failed

    # Already deleted, or a concurrent request won the race: the row is deleted
    # either way, so report success, but record nothing — this request did not
    # perform the deletion.
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
