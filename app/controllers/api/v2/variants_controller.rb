# frozen_string_literal: true

class Api::V2::VariantsController < Api::V2::BaseController
  before_action(only: [:index, :show]) { doorkeeper_authorize!(*Doorkeeper.configuration.public_api_read_scopes.concat([:view_public])) }
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
    ActiveRecord::Base.transaction do
      if !@variant.update(permitted_params)
        raise ActiveRecord::Rollback
      end

      if params.key?(:rich_content)
        @product.lock!
        if @product.has_same_rich_content_for_all_variants?
          raise Link::LinkInvalid, "Cannot update variant rich content while the product uses shared content for all variants. Update product-level rich content instead, or set has_same_rich_content_for_all_variants to false first."
        end

        save_variant_rich_content!(@variant)

        file_ids = @variant.alive_rich_contents.flat_map { _1.embedded_product_file_ids_in_order }.uniq
        if file_ids.any?
          scoped_files = @product.product_files.alive.where(id: file_ids).to_a
          if scoped_files.length != file_ids.length
            missing = file_ids - scoped_files.map(&:id)
            missing_external = missing.map { ObfuscateIds.encrypt(_1) }
            raise Link::LinkInvalid, "File embeds reference files not belonging to this product: #{missing_external.join(", ")}"
          end
          @variant.product_files = scoped_files
        else
          @variant.product_files = []
        end

        Product::SavePostPurchaseCustomFieldsService.new(@product).perform

        @product.reload
        @product.is_licensed = @product.has_embedded_license_key?
        @product.is_multiseat_license = false if !@product.is_licensed
        @product.content_updated_at = Time.current
        @product.save!

        @product.generate_product_files_archives!
      end
    end

    if @variant.errors.any?
      return error_with_variant(@variant)
    end

    @variant.reload if params.key?(:rich_content)
    success_with_variant(@variant)
  rescue JSON::ParserError
    render_response(false, message: "Invalid JSON in rich_content parameter.")
  rescue Link::LinkInvalid => e
    render_response(false, message: e.message)
  rescue ActiveRecord::RecordInvalid => e
    render_response(false, message: e.record.errors.full_messages.to_sentence)
  end

  def destroy
    # Deleting a single version, outside the product editor's deletion guards.
    # Audited for the same reason as the grouping-level destroy: an explicit
    # destructive API call with no confirmation or revision context.
    #
    # A retry must not add a second audit row for one deletion, but that must not
    # be bought by bypassing the model. `update_all` would skip BaseVariant's
    # `after_commit :invalidate_product_cache` and `:update_product_search_index`,
    # leaving stale product caches and stale search state.
    #
    # So lock the row, re-read `deleted_at` under the lock, and keep the original
    # `update_attribute(:deleted_at, ...)` call — deliberately not `mark_deleted`,
    # which additionally enqueues rich-content and archive cleanup workers this
    # endpoint has never run.
    deletion_failed = false

    @variant.with_lock do
      # Re-read under the lock: `@variant` was loaded before it was taken.
      unless @variant.reload.deleted?
        if @variant.update_attribute(:deleted_at, Time.current)
          # Scheduled inside the deletion's transaction, so the audit is only
          # scheduled if the deletion itself commits — a rolled-back deletion
          # records nothing. The audit INSERT then runs after the commit and fails
          # open: if it fails, the deletion still stands and only observability is
          # lost. The two do not commit atomically, and deliberately so.
          ProductVariantDeletionAudit.record_deletion(
            actor_user_id: current_resource_owner&.id,
            product_id: @product.id,
            route: ProductVariantDeletionAudit::API_V2_VARIANT_DESTROY,
            deleted_variant_external_ids: [@variant.external_id],
            intent_source: ProductVariantDeletionAudit::API_EXPLICIT_DESTROY,
            correlation_id: AuditCorrelationId.for(request.request_id),
            request_id: request.request_id,
          )
        else
          deletion_failed = true
        end
      end
    end

    return error_with_variant if deletion_failed

    # Already deleted, or a concurrent request won the race: the row is deleted
    # either way, so report success, but record nothing — this request did not
    # perform the deletion.
    success_with_variant
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
      return error_with_object(:variant_category, nil) if @variant_category.nil?
      @variants = @variant_category.variants
    end

    def success_with_variant(variant = nil)
      if variant
        json = variant.as_json
        json["rich_content"] = variant.rich_content_json
        render_response(true, variant: json)
      else
        success_with_object(:variant, nil)
      end
    end

    def error_with_variant(variant = nil)
      error_with_object(:variant, variant)
    end

    def save_variant_rich_content!(variant)
      raw = params[:rich_content]
      raw = JSON.parse(raw.presence || "[]", symbolize_names: true) if raw.is_a?(String)
      normalized = normalize_params_recursively(raw) || []
      rich_contents_to_keep = []
      existing_rich_contents = variant.alive_rich_contents.to_a

      normalized.each.with_index do |page, index|
        rich_content = existing_rich_contents.find { |c| c.external_id == page[:id] } || variant.alive_rich_contents.build
        description = unwrap_description_content(page[:description])
        description = SaveContentUpsellsService.new(
          seller: current_resource_owner,
          content: description,
          old_content: rich_content.description || []
        ).from_rich_content
        rich_content.assign_attributes(
          title: page[:title].presence,
          description: description.presence || [],
          position: index
        )
        rich_content.remove_stale_dead_cross_product_file_embeds
        rich_content.save!
        rich_contents_to_keep << rich_content
      end

      removed = existing_rich_contents - rich_contents_to_keep
      retire_upsells_from_rich_contents!(removed)
      removed.each(&:mark_deleted!)
    end
end
