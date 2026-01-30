# frozen_string_literal: true

class Products::EditController < Products::BaseController
  def show
    props = presenter.edit_props

    render inertia: "Products/Edit/Index", props:
  end

  def update
    authorize @product

    should_unpublish = params[:unpublish].present? && @product.published?
    was_published = @product.published?

    ActiveRecord::Base.transaction do
      @product.assign_attributes(product_permitted_params.except(
        :custom_button_text_option, :custom_summary, :custom_attributes, :covers, :refund_policy, :product_refund_policy_enabled,
        :seller_refund_policy_enabled, :installment_plan)
      )
      @product.save_custom_button_text_option(product_permitted_params[:custom_button_text_option]) unless product_permitted_params[:custom_button_text_option].nil?
      @product.save_custom_summary(product_permitted_params[:custom_summary]) unless product_permitted_params[:custom_summary].nil?
      @product.save_custom_attributes(product_permitted_params[:custom_attributes]) unless product_permitted_params[:custom_attributes].nil?
      @product.reorder_previews(product_permitted_params[:covers].map.with_index.to_h) if product_permitted_params[:covers].present?
      if !current_seller.account_level_refund_policy_enabled?
        @product.product_refund_policy_enabled = product_permitted_params[:product_refund_policy_enabled]
        if product_permitted_params[:refund_policy].present? && @product.product_refund_policy_enabled
          @product.find_or_initialize_product_refund_policy.update!(product_permitted_params[:refund_policy])
        elsif @product.product_refund_policy_enabled == false && @product.product_refund_policy.present?
          @product.product_refund_policy.destroy
        end
      end

      update_installment_plan
      @product.save!

      @product.unpublish! if should_unpublish
    end

    if should_unpublish
      redirect_back fallback_location: product_edit_path(@product.unique_permalink), notice: "Unpublished!", status: :see_other
    elsif params[:redirect_to].present?
      redirect_to params[:redirect_to], notice: "Changes saved!", status: :see_other
    elsif was_published
      redirect_back fallback_location: product_edit_path(@product.unique_permalink), notice: "Changes saved!", status: :see_other
    else
      redirect_to product_edit_content_path(@product.unique_permalink), notice: "Changes saved!", status: :see_other
    end
  rescue ActiveRecord::RecordNotSaved, ActiveRecord::RecordInvalid, Link::LinkInvalid => e
    error_message = @product.errors.full_messages.first || e.message
    redirect_to product_edit_path(@product.unique_permalink), alert: error_message
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
      return unless @product.eligible_for_installment_plans?

      if @product.installment_plan && product_permitted_params[:installment_plan].present?
        @product.installment_plan.assign_attributes(product_permitted_params[:installment_plan])
        return unless @product.installment_plan.changed?
      end

      @product.installment_plan&.destroy_if_no_payment_options!
      @product.reset_installment_plan

      if product_permitted_params[:installment_plan].present?
        @product.create_installment_plan!(product_permitted_params[:installment_plan])
      end
    end
end
