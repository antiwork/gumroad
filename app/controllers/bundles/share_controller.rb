# frozen_string_literal: true

class Bundles::ShareController < Bundles::BaseController
  before_action :ensure_published

  def edit
    props = BundlePresenter.new(bundle: @bundle).edit_share_props

    render inertia: "Bundles/Share/Edit", props:
  end

  def update
    authorize @bundle

    bundle = nil
    ActiveRecord::Base.transaction do
      bundle = Bundle::UpdateShareService.new(
        bundle: @bundle,
        taxonomy_id: share_permitted_params[:taxonomy_id],
        tags: share_permitted_params[:tags],
        section_ids: share_permitted_params[:section_ids],
        display_product_reviews: share_permitted_params[:display_product_reviews],
        is_adult: share_permitted_params[:is_adult]
      ).perform

      if params[:unpublish].present? && bundle.published?
        bundle.unpublish!
      end
    end

    if params[:unpublish].present?
      redirect_to edit_bundle_content_path(bundle.external_id), notice: "Unpublished!", status: :see_other
    else
      redirect_back fallback_location: edit_bundle_share_path(bundle.external_id), notice: "Changes saved!", status: :see_other
    end
  rescue ActiveRecord::RecordNotSaved, ActiveRecord::RecordInvalid, Link::LinkInvalid => e
    error_message = @bundle.errors.full_messages.first || e.message
    redirect_to edit_bundle_share_path(@bundle.external_id), alert: error_message
  end

  private
    def share_permitted_params
      params.permit(:taxonomy_id, :display_product_reviews, :is_adult, section_ids: [], tags: [])
    end

    def ensure_published
      return if @bundle.published?

      redirect_to edit_bundle_content_path(@bundle.external_id),
                  alert: "Not yet! You've got to publish your awesome product before you can share it with your audience and the world."
    end
end
