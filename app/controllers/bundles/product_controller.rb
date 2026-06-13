# frozen_string_literal: true

class Bundles::ProductController < Bundles::BaseController
  def edit
    props = BundlePresenter.new(bundle: @bundle).edit_product_props

    flash.now[:alert] = "Select products and save your changes to finish converting this product to a bundle." unless @bundle.is_bundle?

    render inertia: "Bundles/Product/Edit", props:
  end

  def update
    authorize @bundle

    should_unpublish = params[:unpublish].present? && @bundle.published?
    was_published = @bundle.published?

    ActiveRecord::Base.transaction do
      @bundle.is_bundle = true
      @bundle.native_type = Link::NATIVE_TYPE_BUNDLE
      @bundle.assign_attributes(product_permitted_params.except(
        :custom_button_text_option, :custom_summary, :custom_attributes, :covers, :refund_policy, :product_refund_policy_enabled,
        :seller_refund_policy_enabled, :installment_plan)
      )
      @bundle.save_custom_button_text_option(product_permitted_params[:custom_button_text_option]) unless product_permitted_params[:custom_button_text_option].nil?
      @bundle.save_custom_summary(product_permitted_params[:custom_summary]) unless product_permitted_params[:custom_summary].nil?
      @bundle.save_custom_attributes(product_permitted_params[:custom_attributes]) unless product_permitted_params[:custom_attributes].nil?
      @bundle.reorder_previews(product_permitted_params[:covers].map.with_index.to_h) if product_permitted_params[:covers].present?
      if !current_seller.account_level_refund_policy_enabled?
        @bundle.product_refund_policy_enabled = product_permitted_params[:product_refund_policy_enabled]
        if product_permitted_params[:refund_policy].present? && @bundle.product_refund_policy_enabled
          @bundle.find_or_initialize_product_refund_policy.update!(product_permitted_params[:refund_policy])
        elsif @bundle.product_refund_policy_enabled == false && @bundle.product_refund_policy.present?
          @bundle.product_refund_policy.destroy
        end
      end

      update_installment_plan
      @bundle.save!

      @bundle.unpublish! if should_unpublish
    end

    if should_unpublish
      redirect_back fallback_location: edit_bundle_product_path(@bundle.external_id), notice: "Unpublished!", status: :see_other
    elsif params[:redirect_to].present?
      redirect_to params[:redirect_to], notice: "Changes saved!", status: :see_other
    elsif was_published
      redirect_back fallback_location: edit_bundle_product_path(@bundle.external_id), notice: "Changes saved!", status: :see_other
    else
      redirect_to edit_bundle_content_path(@bundle.external_id), notice: "Changes saved!", status: :see_other
    end
  rescue ActiveRecord::RecordNotSaved, ActiveRecord::RecordInvalid, Link::LinkInvalid => e
    error_message = @bundle.errors.full_messages.first || e.message
    redirect_to edit_bundle_product_path(@bundle.external_id), alert: error_message
  end

  private
    def product_permitted_params
      params.permit(
        :name,
        :description,
        :custom_permalink,
        :price_cents,
        :customizable_price,
        :suggested_price_cents,
        :max_purchase_count,
        :quantity_enabled,
        :should_show_sales_count,
        :custom_button_text_option,
        :custom_summary,
        :is_epublication,
        :product_refund_policy_enabled,
        :seller_refund_policy_enabled,
        refund_policy: [:max_refund_period_in_days, :title, :fine_print],
        covers: [],
        custom_attributes: [:name, :value],
        installment_plan: [:number_of_installments]
      )
    end

    def update_installment_plan
      return unless @bundle.eligible_for_installment_plans?

      if @bundle.installment_plan && product_permitted_params[:installment_plan].present?
        @bundle.installment_plan.assign_attributes(product_permitted_params[:installment_plan])
        return unless @bundle.installment_plan.changed?
      end

      @bundle.installment_plan&.destroy_if_no_payment_options!
      @bundle.reset_installment_plan

      if product_permitted_params[:installment_plan].present?
        @bundle.create_installment_plan!(product_permitted_params[:installment_plan])
      end
    end
end
