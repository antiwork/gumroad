# frozen_string_literal: true

class Products::ProductTabController < Products::BaseTabController
  def edit
    return redirect_to edit_bundle_product_path(@product.external_id) if @product.is_bundle?
    set_meta_tag(title: @product.name)
    render inertia: "Products/Edit/ProductTab", props: presenter.edit_props
  end

  def update
    handle_update do
      @product.assign_attributes(product_tab_params.except(
        :description,
        :custom_button_text_option,
        :custom_summary,
        :custom_attributes,
        :covers,
        :refund_policy,
        :product_refund_policy_enabled,
        :integrations,
        :variants,
        :tags,
        :section_ids,
        :availabilities,
        :shipping_destinations,
        :cancellation_discount,
        :default_offer_code_id
      ))

      permitted = product_tab_params

      @product.description = SaveContentUpsellsService.new(
        seller: @product.user,
        content: permitted[:description],
        old_content: @product.description_was
      ).from_html if permitted[:description]

      @product.save_custom_button_text_option(permitted[:custom_button_text_option]) if permitted[:custom_button_text_option]
      @product.save_custom_summary(permitted[:custom_summary]) if permitted[:custom_summary]
      @product.save_custom_attributes((permitted[:custom_attributes] || []).filter { _1[:name].present? || _1[:description].present? })
      @product.save_tags!(permitted[:tags] || [])
      @product.reorder_previews((permitted[:covers] || []).map.with_index.to_h)

      unless current_seller.account_level_refund_policy_enabled?
        @product.product_refund_policy_enabled = permitted[:product_refund_policy_enabled]
        if permitted[:refund_policy].present? && permitted[:product_refund_policy_enabled]
          @product.find_or_initialize_product_refund_policy.update!(permitted[:refund_policy])
        end
      end

      if Feature.active?(:cancellation_discounts, @product.user) && (permitted[:cancellation_discount].present? || @product.cancellation_discount_offer_code.present?)
        Product::SaveCancellationDiscountService.new(@product, permitted[:cancellation_discount]).perform
      end

      if @product.native_type == Link::NATIVE_TYPE_COFFEE
        @product.suggested_price_cents = permitted[:variants]&.map { _1[:price_difference_cents] }&.max
      end

      Product::SaveIntegrationsService.perform(@product, permitted[:integrations])

      variant_category = @product.variant_categories_alive.first
      variants = permitted[:variants] || []
      if variants.any? || @product.is_tiered_membership?
        variant_category_params = variant_category.present? ?
          { id: variant_category.external_id, name: variant_category.title } :
          { name: @product.is_tiered_membership? ? "Tier" : "Version" }
        Product::VariantsUpdaterService.new(
          product: @product,
          variants_params: [{ **variant_category_params, options: variants }]
        ).perform
      elsif variant_category.present?
        Product::VariantsUpdaterService.new(
          product: @product,
          variants_params: [{ id: variant_category.external_id, options: nil }]
        ).perform
      end

      @product.save_shipping_destinations!(permitted[:shipping_destinations] || []) if @product.is_physical

      @product.save!
    end
  end

  private

    def product_tab_params
      params.require(:link).permit(
        :name, :description, :custom_permalink, :price_cents, :price_currency_type,
        :customizable_price, :suggested_price_cents, :native_type, :is_adult,
        :max_purchase_count, :quantity_enabled, :should_show_sales_count,
        :hide_sold_out_variants, :is_epublication, :product_refund_policy_enabled,
        :custom_button_text_option, :custom_summary, :custom_domain,
        :free_trial_enabled, :free_trial_duration_amount, :free_trial_duration_unit,
        :should_include_last_post, :should_show_all_posts,
        :block_access_after_membership_cancellation, :duration_in_months,
        :subscription_duration, :require_shipping, :display_product_reviews,
        :default_offer_code_id, :lock_version,
        covers: [],
        tags: [],
        section_ids: [],
        custom_attributes: [:name, :value],
        refund_policy: [:max_refund_period_in_days, :fine_print, :title],
        integrations: {},
        variants: [
          :id, :name, :description, :max_purchase_count, :price_difference_cents,
          :customizable_price, :apply_price_changes_to_existing_memberships,
          :subscription_price_change_effective_date, :subscription_price_change_message,
          :duration_in_minutes,
          integrations: {},
          recurrence_price_values: {}
        ],
        availabilities: [:id, :start_time, :end_time],
        shipping_destinations: [:country_code, :one_item_rate_cents, :multiple_items_rate_cents],
        cancellation_discount: [:duration_in_billing_cycles, discount: [:type, :cents, :percents]]
      )
    end
end
