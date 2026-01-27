# frozen_string_literal: true

module Bundles
  class ProductController < Sellers::BaseController
    layout "inertia"

    def edit
      bundle = Link.can_be_bundle.find_by_external_id!(params[:bundle_id])
      authorize bundle

      set_meta_tag(title: bundle.name)

      props = BundlePresenter.new(bundle:).bundle_props

      render inertia: "Bundles/Product/Edit", props:
    end

    def update
      bundle = Link.can_be_bundle.find_by_external_id!(params[:bundle_id])
      authorize bundle

      begin
        bundle.is_bundle = true
        bundle.native_type = Link::NATIVE_TYPE_BUNDLE
        
        # Update basic attributes
        bundle.assign_attributes(product_permitted_params.except(
          :custom_button_text_option, :custom_summary, :custom_attributes, :covers, :collaborating_user
        ))
        
        # Update special fields
        bundle.save_custom_button_text_option(product_permitted_params[:custom_button_text_option]) unless product_permitted_params[:custom_button_text_option].nil?
        bundle.save_custom_summary(product_permitted_params[:custom_summary]) unless product_permitted_params[:custom_summary].nil?
        bundle.save_custom_attributes(product_permitted_params[:custom_attributes]) unless product_permitted_params[:custom_attributes].nil?
        bundle.reorder_previews(product_permitted_params[:covers].map.with_index.to_h) if product_permitted_params[:covers].present?
        
        bundle.save!
      rescue ActiveRecord::RecordNotSaved, ActiveRecord::RecordInvalid, Link::LinkInvalid => e
        error_message = bundle.errors.full_messages.first || e.message
        return redirect_back fallback_location: edit_bundles_product_path(params[:bundle_id]), 
                             inertia: { errors: { base: error_message } }
      end

      redirect_to edit_bundles_product_path(params[:bundle_id]), notice: "Changes saved!"
    end

    private

    def product_permitted_params
      params.permit(policy(Link.find_by_external_id!(params[:bundle_id])).bundle_permitted_attributes)
    end
  end
end
