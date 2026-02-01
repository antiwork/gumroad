# frozen_string_literal: true

class Products::ProductController < Products::BaseController
  def edit
    return redirect_to edit_bundle_product_path(@product.external_id) if @product.is_bundle?

    set_meta_tag(title: @product.name)

    ai_generated = params[:ai_generated] == "true"

    render inertia: "Products/Product/Edit", props: presenter.edit_product_props(ai_generated:)
  end

  def update
    should_unpublish = params[:unpublish].present? && @product.published?

    ActiveRecord::Base.transaction do
      @product.assign_attributes(product_permitted_params.except(
        :custom_button_text_option,
        :custom_summary,
        :custom_attributes,
        :covers,
        :refund_policy,
        :product_refund_policy_enabled,
        :integrations,
        :shipping_destinations,
        :call_limitation_info,
        :installment_plan,
        :default_offer_code_id
      ))

      @product.save_custom_button_text_option(product_permitted_params[:custom_button_text_option]) unless product_permitted_params[:custom_button_text_option].nil?
      @product.save_custom_summary(product_permitted_params[:custom_summary]) unless product_permitted_params[:custom_summary].nil?
      @product.save_custom_attributes((product_permitted_params[:custom_attributes] || []).filter { _1[:name].present? || _1[:description].present? })
      @product.reorder_previews((product_permitted_params[:covers] || []).map.with_index.to_h)

      unless current_seller.account_level_refund_policy_enabled?
        @product.product_refund_policy_enabled = product_permitted_params[:product_refund_policy_enabled]
        if product_permitted_params[:refund_policy].present? && product_permitted_params[:product_refund_policy_enabled]
          @product.find_or_initialize_product_refund_policy.update!(product_permitted_params[:refund_policy])
        elsif product_permitted_params[:product_refund_policy_enabled] == false && @product.product_refund_policy.present?
          @product.product_refund_policy.destroy
        end
      end

      @product.save_shipping_destinations!(product_permitted_params[:shipping_destinations] || []) if @product.is_physical

      Product::SaveIntegrationsService.perform(@product, product_permitted_params[:integrations])
      update_call_limitation_info
      update_installment_plan
      update_default_offer_code

      @product.save!
      @product.unpublish! if should_unpublish
    end

    if should_unpublish
      redirect_back fallback_location: edit_product_product_path(@product.external_id), notice: "Unpublished!", status: :see_other
    elsif params[:redirect_to].present?
      redirect_to params[:redirect_to], notice: "Changes saved!", status: :see_other
    else
      redirect_back fallback_location: edit_product_product_path(@product.external_id), notice: "Changes saved!", status: :see_other
    end
  rescue ActiveRecord::RecordNotSaved, ActiveRecord::RecordInvalid, Link::LinkInvalid => e
    error_message = @product.errors.full_messages.first || e.message
    redirect_to edit_product_product_path(@product.external_id), alert: error_message, inertia: inertia_errors(@product)
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
        :hide_sold_out_variants,
        :is_epublication,
        :custom_button_text_option,
        :custom_summary,
        :require_shipping,
        :product_refund_policy_enabled,
        :free_trial_enabled,
        :free_trial_duration_amount,
        :free_trial_duration_unit,
        :should_include_last_post,
        :should_show_all_posts,
        :block_access_after_membership_cancellation,
        :duration_in_months,
        :subscription_duration,
        :default_offer_code_id,
        covers: [],
        custom_attributes: [:name, :value],
        refund_policy: [:max_refund_period_in_days, :title, :fine_print],
        integrations: {},
        shipping_destinations: [:country_code, :one_item_rate_cents, :multiple_items_rate_cents],
        call_limitation_info: [:minimum_notice_in_minutes, :maximum_calls_per_day],
        installment_plan: [:number_of_installments]
      )
    end

    def update_call_limitation_info
      return unless @product.native_type == Link::NATIVE_TYPE_CALL

      if product_permitted_params[:call_limitation_info].present?
        info = @product.call_limitation_info || @product.build_call_limitation_info
        info.assign_attributes(product_permitted_params[:call_limitation_info])
        info.save! if info.changed?
      elsif @product.call_limitation_info.present?
        @product.call_limitation_info.destroy
      end
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

    def update_default_offer_code
      return unless product_permitted_params[:default_offer_code_id].present?

      offer_code_id = ObfuscateIds.decrypt(product_permitted_params[:default_offer_code_id])
      offer_code = @product.user.offer_codes.find_by(id: offer_code_id)

      if offer_code && offer_code.can_be_default_for?(@product)
        @product.update!(default_offer_code: offer_code)
      elsif product_permitted_params[:default_offer_code_id] == "none"
        @product.update!(default_offer_code: nil)
      end
    end
end
