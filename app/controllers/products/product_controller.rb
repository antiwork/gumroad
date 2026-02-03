# frozen_string_literal: true

class Products::ProductController < Products::BaseController
  def edit
    return redirect_to bundle_path(@product.external_id) if @product.is_bundle?

    render inertia: "Products/Product/Edit", props: Products::Edit::ProductTabPresenter.new(product: @product, pundit_user:).props
  end

  def update
    authorize @product

    should_publish = params[:publish].present? && !@product.published?
    should_unpublish = params[:unpublish].present? && @product.published?
    was_published = @product.published?

    if should_unpublish
      @product.unpublish!
      check_offer_codes_validity
      return redirect_back fallback_location: edit_product_product_path(@product.unique_permalink), notice: "Unpublished!", status: :see_other
    end

    # Publish-only request (e.g. after "Save" then "Publish and continue" from frontend)
    if should_publish && params[:product].blank?
      @product.publish!
      check_offer_codes_validity
      return redirect_to edit_product_share_path(@product.unique_permalink), notice: "Published!", status: :see_other
    end

    ActiveRecord::Base.transaction do
      update_product_attributes
      @product.publish! if should_publish
    end

    check_offer_codes_validity

    if should_publish
      redirect_to edit_product_share_path(@product.unique_permalink), notice: "Published!", status: :see_other
    elsif (path = safe_redirect_path(params[:redirect_to])).present?
      redirect_to path, notice: "Changes saved!", status: :see_other
    elsif was_published
      redirect_back fallback_location: edit_product_product_path(@product.unique_permalink), notice: "Changes saved!", status: :see_other
    else
      redirect_to edit_product_content_path(@product.unique_permalink), notice: "Changes saved!", status: :see_other
    end
  rescue ActiveRecord::RecordNotSaved, ActiveRecord::RecordInvalid, Link::LinkInvalid => e
    error_message = if @product.errors.details[:custom_fields].present?
      "You must add titles to all of your inputs"
    else
      @product.errors.full_messages.first || e.message
    end
    redirect_to edit_product_product_path(@product.unique_permalink), alert: error_message, status: :see_other
  end

  private

    def update_product_attributes
      @product.assign_attributes(product_permitted_params.except(
        :description,
        :cancellation_discount,
        :custom_button_text_option,
        :custom_summary,
        :custom_attributes,
        :covers,
        :integrations,
        :variants,
        :section_ids,
        :availabilities,
        :call_limitation_info,
        :installment_plan,
        :default_offer_code_id,
        :public_files,
        :shipping_destinations,
        :community_chat_enabled,
        :custom_domain,
        :file_attributes,
        :refund_policy
      ))

      if @product.native_type === ::Link::NATIVE_TYPE_COFFEE && product_permitted_params[:variants].present?
        @product.suggested_price_cents = product_permitted_params[:variants].map { _1[:price_difference_cents] }.max
      end

      @product.description = SaveContentUpsellsService.new(
        seller: @product.user,
        content: product_permitted_params[:description],
        old_content: @product.description_was
      ).from_html if product_permitted_params[:description].present?

      @product.save_custom_button_text_option(product_permitted_params[:custom_button_text_option]) unless product_permitted_params[:custom_button_text_option].nil?
      @product.save_custom_summary(product_permitted_params[:custom_summary]) unless product_permitted_params[:custom_summary].nil?
      @product.save_custom_attributes((product_permitted_params[:custom_attributes] || []).filter { _1[:name].present? || _1[:description].present? })
      @product.reorder_previews((product_permitted_params[:covers] || []).map.with_index.to_h)
      @product.show_in_sections!(product_permitted_params[:section_ids] || [])
      @product.save_shipping_destinations!(product_permitted_params[:shipping_destinations] || []) if @product.is_physical

      if Feature.active?(:cancellation_discounts, @product.user) && (product_permitted_params[:cancellation_discount].present? || @product.cancellation_discount_offer_code.present?)
        Product::SaveCancellationDiscountService.new(@product, product_permitted_params[:cancellation_discount].to_h.symbolize_keys.deep_symbolize_keys).perform
      end

      Product::SaveIntegrationsService.perform(@product, product_permitted_params[:integrations])
      update_variants
      update_availabilities
      update_call_limitation_info
      update_installment_plan
      update_default_offer_code

      Product::SavePostPurchaseCustomFieldsService.new(@product).perform

      @product.description = SavePublicFilesService.new(
        resource: @product,
        files_params: product_permitted_params[:public_files],
        content: @product.description
      ).process if product_permitted_params[:public_files].present?

      toggle_community_chat!(product_permitted_params[:community_chat_enabled])
      @product.save!
    end

    def update_variants
      variant_category = @product.variant_categories_alive.first
      variants = product_permitted_params[:variants] || []
      if variants.any? || @product.is_tiered_membership?
        variant_category_params = variant_category.present? ?
          { id: variant_category.external_id, name: variant_category.title } :
          { name: @product.is_tiered_membership? ? "Tier" : "Version" }

        Product::VariantsUpdaterService.new(
          product: @product,
          variants_params: [{ **variant_category_params, options: variants }],
        ).perform
      elsif variant_category.present?
        Product::VariantsUpdaterService.new(
          product: @product,
          variants_params: [{ id: variant_category.external_id, options: nil }]
        ).perform
      end
    end

    def update_availabilities
      return unless @product.native_type == ::Link::NATIVE_TYPE_CALL
      existing_availabilities = @product.call_availabilities
      availabilities_to_keep = []
      (product_permitted_params[:availabilities] || []).each do |availability_params|
        availability = existing_availabilities.find { _1.external_id == availability_params[:id] } || @product.call_availabilities.build
        availability.update!(availability_params.except(:id))
        availabilities_to_keep << availability
      end
      (existing_availabilities - availabilities_to_keep).each(&:destroy!)
    end

    def update_call_limitation_info
      return unless @product.native_type == ::Link::NATIVE_TYPE_CALL
      call_limitation_params = product_permitted_params[:call_limitation_info].presence ||
        params[:product]&.permit(call_limitation_info: [:minimum_notice_in_minutes, :maximum_calls_per_day])[:call_limitation_info]
      if call_limitation_params.present?
        @product.call_limitation_info.update!(call_limitation_params.to_h.symbolize_keys)
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
      default_offer_code_id = product_permitted_params[:default_offer_code_id]
      return @product.default_offer_code = nil if default_offer_code_id.blank?

      offer_code = @product.user.offer_codes.alive.find_by_external_id!(default_offer_code_id)
      raise ::Link::LinkInvalid, "Offer code cannot be expired" if offer_code.inactive?
      raise ::Link::LinkInvalid, "Offer code must be associated with this product or be universal" unless valid_for_product?(offer_code)
      @product.default_offer_code = offer_code
    rescue ActiveRecord::RecordNotFound
      raise ::Link::LinkInvalid, "Invalid offer code"
    end

    def valid_for_product?(offer_code)
      offer_code.universal? || @product.offer_codes.where(id: offer_code.id).exists?
    end

    def toggle_community_chat!(enabled)
      return if enabled.nil?
      return unless Feature.active?(:communities, current_seller)
      return if [::Link::NATIVE_TYPE_COFFEE, ::Link::NATIVE_TYPE_BUNDLE].include?(@product.native_type)
      @product.toggle_community_chat!(enabled)
    end

    def product_permitted_params
      params.require(:product).permit(policy(@product).product_tab_permitted_attributes)
    end
end
