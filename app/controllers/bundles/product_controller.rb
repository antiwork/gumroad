# frozen_string_literal: true

module Bundles
  class ProductController < Sellers::BaseController
    layout "inertia"

    def edit
      bundle = Link.can_be_bundle.find_by_external_id!(params[:bundle_id])
      authorize bundle

      set_meta_tag(title: bundle.name)

      props = BundlePresenter.new(bundle:).bundle_props
      
      # Only expose props needed for Product tab
      props = props.slice(
        :bundle, :id, :unique_permalink, :currency_type, :thumbnail,
        :sales_count_for_inventory, :ratings, :taxonomies, :profile_sections,
        :refund_policies, :products_count, :is_bundle, :has_outdated_purchases,
        :seller_refund_policy_enabled, :seller_refund_policy
      )

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
          :custom_button_text_option, :custom_summary, :custom_attributes, :covers, :refund_policy, 
          :product_refund_policy_enabled, :installment_plan, :collaborating_user
        ))
        
        # Update special fields
        bundle.save_custom_button_text_option(product_permitted_params[:custom_button_text_option]) unless product_permitted_params[:custom_button_text_option].nil?
        bundle.save_custom_summary(product_permitted_params[:custom_summary]) unless product_permitted_params[:custom_summary].nil?
        bundle.save_custom_attributes(product_permitted_params[:custom_attributes]) unless product_permitted_params[:custom_attributes].nil?
        bundle.reorder_previews(product_permitted_params[:covers].map.with_index.to_h) if product_permitted_params[:covers].present?
        
        # Handle refund policy
        if !current_seller.account_level_refund_policy_enabled?
          bundle.product_refund_policy_enabled = product_permitted_params[:product_refund_policy_enabled]
          if product_permitted_params[:refund_policy].present? && product_permitted_params[:product_refund_policy_enabled]
            bundle.find_or_initialize_product_refund_policy.update!(product_permitted_params[:refund_policy])
          end
        end
        
        # Handle installment plan
        update_installment_plan(bundle, product_permitted_params)
        
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
    
    def update_installment_plan(bundle, permitted_params)
      return unless bundle.eligible_for_installment_plans?

      if bundle.installment_plan && permitted_params[:installment_plan].present?
        bundle.installment_plan.assign_attributes(permitted_params[:installment_plan])
        return unless bundle.installment_plan.changed?
      end

      bundle.installment_plan&.destroy_if_no_payment_options!
      bundle.reset_installment_plan

      if permitted_params[:installment_plan].present?
        bundle.create_installment_plan!(permitted_params[:installment_plan])
      end
    end
  end
end
