# frozen_string_literal: true

module Bundles
  class ShareController < Sellers::BaseController
    layout "inertia"

    def edit
      bundle = Link.can_be_bundle.find_by_external_id!(params[:bundle_id])
      authorize bundle

      set_meta_tag(title: bundle.name)

      props = BundlePresenter.new(bundle:).bundle_props

      render inertia: "Bundles/Share/Edit", props:
    end

    def update
      bundle = Link.can_be_bundle.find_by_external_id!(params[:bundle_id])
      authorize bundle

      begin
        # Update share-related fields
        bundle.save_tags!(share_permitted_params[:tags]) unless share_permitted_params[:tags].nil?
        bundle.assign_attributes(share_permitted_params.except(:tags, :section_ids))
        bundle.show_in_sections!(share_permitted_params[:section_ids]) if share_permitted_params[:section_ids]
        
        bundle.save!
      rescue ActiveRecord::RecordNotSaved, ActiveRecord::RecordInvalid, Link::LinkInvalid => e
        error_message = bundle.errors.full_messages.first || e.message
        return redirect_back fallback_location: edit_bundles_share_path(params[:bundle_id]), 
                             inertia: { errors: { base: error_message } }
      end

      redirect_to edit_bundles_share_path(params[:bundle_id]), notice: "Changes saved!"
    end

    private

    def share_permitted_params
      params.permit(
        :taxonomy_id, 
        :display_product_reviews, 
        :is_adult, 
        :discover_fee_per_thousand,
        tags: [],
        section_ids: []
      )
    end
  end
end
