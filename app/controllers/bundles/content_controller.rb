# frozen_string_literal: true

class Bundles::ContentController < Bundles::BaseController
  def edit
    props = BundlePresenter.new(bundle: @bundle).edit_content_props

    props[:search_data] = InertiaRails.defer(merge: true) { search_results }

    flash.now[:alert] = "Select products and save your changes to finish converting this product to a bundle." unless @bundle.is_bundle?

    render inertia: "Bundles/Content/Edit", props:
  end

  def update
    authorize @bundle

    should_publish = params[:publish].present? && !@bundle.published?
    should_unpublish = params[:unpublish].present? && @bundle.published?

    bundle = nil
    ActiveRecord::Base.transaction do
      @bundle.is_bundle = true
      @bundle.native_type = Link::NATIVE_TYPE_BUNDLE
      bundle = Bundle::UpdateProductsService.new(bundle: @bundle, products: content_permitted_params).perform

      bundle.publish! if should_publish
      bundle.unpublish! if should_unpublish
    end

    if should_publish
      redirect_to edit_bundle_share_path(bundle.external_id), notice: "Published!", status: :see_other
    elsif should_unpublish
      redirect_back fallback_location: edit_bundle_content_path(bundle.external_id), notice: "Unpublished!", status: :see_other
    elsif params[:redirect_to].present?
      redirect_to params[:redirect_to], notice: "Changes saved!", status: :see_other
    else
      redirect_back fallback_location: edit_bundle_content_path(bundle.external_id), notice: "Changes saved!", status: :see_other
    end
  rescue ActiveRecord::RecordNotSaved, ActiveRecord::RecordInvalid, Link::LinkInvalid => e
    error_message = @bundle.errors.full_messages.first || e.message
    redirect_to edit_bundle_content_path(@bundle.external_id), alert: error_message
  end

  def update_purchases_content
    if @bundle.has_outdated_purchases?
      @bundle.update!(has_outdated_purchases: false)
      UpdateBundlePurchasesContentJob.perform_async(@bundle.id)
      redirect_to edit_bundle_content_path(@bundle.external_id), notice: "Queued an update to the content of all outdated purchases.", status: :see_other
    else
      redirect_to edit_bundle_content_path(@bundle.external_id), alert: "This bundle has no purchases with outdated content."
    end
  end

  private
    def content_permitted_params
      params.permit(products: %i[product_id variant_id quantity position]).fetch(:products, [])
    end

    def search_results
      @search_results ||= BundleSearchProductsService.new(
        bundle: @bundle,
        seller: current_seller,
        query: params[:query].presence,
        page: params[:page].presence || 1,
        all: params[:all] == "true"
      ).call
    end
end
