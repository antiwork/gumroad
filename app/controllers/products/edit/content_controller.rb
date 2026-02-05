# frozen_string_literal: true

class Products::Edit::ContentController < Products::Edit::BaseController
  def show
    return redirect_to bundle_path(@product.external_id) if @product.is_bundle?

    set_product_title

    @presenter = ProductPresenter.new(product: @product, pundit_user:)

    render inertia: "Products/Edit/Content", props: @presenter.edit_props
  end

  def update
    begin
       ActiveRecord::Base.transaction do
         @product.assign_attributes(product_permitted_params.except(
           :products,
           :description,
           :cancellation_discount,
           :custom_button_text_option,
           :custom_summary,
           :custom_attributes,
           :file_attributes,
           :covers,
           :refund_policy,
           :product_refund_policy_enabled,
           :seller_refund_policy_enabled,
           :integrations,
           :variants,
           :tags,
           :section_ids,
           :availabilities,
           :custom_domain,
           :rich_content,
           :files,
           :public_files,
           :shipping_destinations,
           :call_limitation_info,
           :installment_plan,
           :community_chat_enabled,
           :default_offer_code_id
         ))
         @product.description = SaveContentUpsellsService.new(seller: @product.user, content: product_permitted_params[:description], old_content: @product.description_was).from_html
         @product.skus_enabled = false
         @product.save_custom_button_text_option(product_permitted_params[:custom_button_text_option]) unless product_permitted_params[:custom_button_text_option].nil?
         @product.save_custom_summary(product_permitted_params[:custom_summary]) unless product_permitted_params[:custom_summary].nil?
         @product.save_custom_attributes((product_permitted_params[:custom_attributes] || []).filter { _1[:name].present? || _1[:description].present? })
         @product.save_tags!(product_permitted_params[:tags] || [])
         @product.reorder_previews((product_permitted_params[:covers] || []).map.with_index.to_h)
         if !current_seller.account_level_refund_policy_enabled?
           @product.product_refund_policy_enabled = product_permitted_params[:product_refund_policy_enabled]
           if product_permitted_params[:refund_policy].present? && product_permitted_params[:product_refund_policy_enabled]
             @product.find_or_initialize_product_refund_policy.update!(product_permitted_params[:refund_policy])
           end
         end
         @product.show_in_sections!(product_permitted_params[:section_ids] || [])
         @product.save_shipping_destinations!(product_permitted_params[:shipping_destinations] || []) if @product.is_physical

         if Feature.active?(:cancellation_discounts, @product.user) && (product_permitted_params[:cancellation_discount].present? || @product.cancellation_discount_offer_code.present?)
           begin
             Product::SaveCancellationDiscountService.new(@product, product_permitted_params[:cancellation_discount]).perform
           rescue ActiveRecord::RecordInvalid => e
             return render json: { error_message: e.record.errors.full_messages.first }, status: :unprocessable_entity
           end
         end

         if @product.native_type === Link::NATIVE_TYPE_COFFEE
           @product.suggested_price_cents = product_permitted_params[:variants].map { _1[:price_difference_cents] }.max
         end

         # TODO clean this up
         rich_content = product_permitted_params[:rich_content] || []
         rich_content_params = [*rich_content]
         product_permitted_params[:variants].each { rich_content_params.push(*_1[:rich_content]) } if product_permitted_params[:variants].present?
         rich_content_params = rich_content_params.flat_map { _1[:description] = _1.dig(:description, :content) }
         rich_contents_to_keep = []
         SaveFilesService.perform(@product, product_permitted_params, rich_content_params)
         existing_rich_contents = @product.alive_rich_contents.to_a
         rich_content.each.with_index do |product_rich_content, index|
           rich_content = existing_rich_contents.find { |c| c.external_id === product_rich_content[:id] } || @product.alive_rich_contents.build
           product_rich_content[:description] = SaveContentUpsellsService.new(seller: @product.user, content: product_rich_content[:description], old_content: rich_content.description || []).from_rich_content
           rich_content.update!(title: product_rich_content[:title].presence, description: product_rich_content[:description].presence || [], position: index)
           rich_contents_to_keep << rich_content
         end
         (existing_rich_contents - rich_contents_to_keep).each(&:mark_deleted!)

         Product::SaveIntegrationsService.perform(@product, product_permitted_params[:integrations])
         update_variants
         update_removed_file_attributes
         update_custom_domain
         update_availabilities
         update_call_limitation_info
         update_installment_plan
         update_default_offer_code

         Product::SavePostPurchaseCustomFieldsService.new(@product).perform

         @product.is_licensed = @product.has_embedded_license_key?
         unless @product.is_licensed
           @product.is_multiseat_license = false
         end
         @product.description = SavePublicFilesService.new(resource: @product, files_params: product_permitted_params[:public_files], content: @product.description).process
         @product.save!
         toggle_community_chat!(product_permitted_params[:community_chat_enabled])
         @product.generate_product_files_archives!
       end
      rescue ActiveRecord::RecordNotSaved, ActiveRecord::RecordInvalid, Link::LinkInvalid => e
        if @product.errors.details[:custom_fields].present?
          error_message = "You must add titles to all of your inputs"
        else
          error_message = @product.errors.full_messages.first || e.message
        end
        return redirect_to products_edit_content_path(@product.unique_permalink), alert: error_message
     end

    invalid_currency_offer_codes = @product.product_and_universal_offer_codes.reject do |offer_code|
      offer_code.is_currency_valid?(@product)
    end.map(&:code)
    invalid_amount_offer_codes = @product.product_and_universal_offer_codes.reject { _1.is_amount_valid?(@product) }.map(&:code)

    all_invalid_offer_codes = (invalid_currency_offer_codes + invalid_amount_offer_codes).uniq

    if all_invalid_offer_codes.any?
      # Determine the main issue type for the message
      has_currency_issues = invalid_currency_offer_codes.any?
      has_amount_issues = invalid_amount_offer_codes.any?

      if has_currency_issues && has_amount_issues
        issue_description = "#{"has".pluralize(all_invalid_offer_codes.count)} currency mismatches or would discount this product below #{@product.min_price_formatted}"
      elsif has_currency_issues
        issue_description = "#{"has".pluralize(all_invalid_offer_codes.count)} currency #{"mismatch".pluralize(all_invalid_offer_codes.count)} with this product"
      else
        issue_description = "#{all_invalid_offer_codes.count > 1 ? "discount" : "discounts"} this product below #{@product.min_price_formatted}, but not to #{MoneyFormatter.format(0, @product.price_currency_type.to_sym, no_cents_if_whole: true, symbol: true)}"
      end

      return redirect_to products_edit_content_path(@product.unique_permalink), warning: "The following offer #{"code".pluralize(all_invalid_offer_codes.count)} #{issue_description}: #{all_invalid_offer_codes.join(", ")}. Please update #{all_invalid_offer_codes.length > 1 ? "them or they" : "it or it"} will not work at checkout."
    end

    if params[:redirect_to].present?
      redirect_to params[:redirect_to], notice: "Changes saved successfully!", status: :see_other
    else
      redirect_to products_edit_content_path(@product.unique_permalink), notice: "Changes saved successfully!", status: :see_other
    end
  end
end
