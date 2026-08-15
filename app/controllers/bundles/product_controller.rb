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
    currency_before = @bundle.price_currency_type
    offer_codes_before_currency_change = nil

    ActiveRecord::Base.transaction do
      @bundle.is_bundle = true
      @bundle.native_type = Link::NATIVE_TYPE_BUNDLE
      # Currency must land before the amount: `price_cents=` files a Price row under
      # whatever `price_currency_type` reads at that instant, and assign_attributes
      # follows client key order. Carries the stored amount when the form omits it.
      changing_currency = product_permitted_params.key?(:price_currency_type)
      if changing_currency
        # universal_offer_codes scopes on the current price_currency_type, so
        # old-currency universal codes vanish from the list the moment the new
        # currency lands — capture the candidates while it still reads the old one.
        offer_codes_before_currency_change = @bundle.product_and_universal_offer_codes
        carried_price_cents = product_permitted_params[:price_cents].presence || @bundle.price_cents
        @bundle.price_currency_type = product_permitted_params[:price_currency_type]
        @bundle.price_cents = carried_price_cents if carried_price_cents.present?
      end
      skipped_params = [
        :custom_button_text_option, :custom_summary, :custom_attributes, :covers, :refund_policy, :product_refund_policy_enabled,
        :seller_refund_policy_enabled, :installment_plan, :default_offer_code_id, :price_currency_type
      ]
      skipped_params << :price_cents if changing_currency
      @bundle.assign_attributes(product_permitted_params.except(*skipped_params))
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
      update_default_offer_code
      @bundle.save!

      @bundle.unpublish! if should_unpublish
    end

    notice = "Changes saved!"
    # A bundle's own fixed-amount codes survive a currency change unflagged:
    # clear_detached_default_offer_code only currency-checks universal ones, and
    # applicable? skips the check entirely for product-specific codes. Warn like
    # LinksController#update does, or the discount silently stops quoting.
    if currency_before != @bundle.price_currency_type
      offer_code_candidates = (offer_codes_before_currency_change || []) | @bundle.product_and_universal_offer_codes
      stale_codes = offer_code_candidates.reject do |offer_code|
        offer_code.is_currency_valid?(@bundle) && offer_code.is_amount_valid?(@bundle)
      end.map(&:code)

      if stale_codes.any?
        notice = nil
        flash[:warning] = "Changes saved, but the following offer #{"code".pluralize(stale_codes.count)} no longer #{stale_codes.one? ? "matches" : "match"} this bundle's currency and will not apply at checkout: #{stale_codes.join(", ")}."
      end
    end

    if should_unpublish
      redirect_back fallback_location: edit_bundle_product_path(@bundle.external_id), notice: "Unpublished!", status: :see_other
    elsif params[:redirect_to].present?
      redirect_to safe_redirect_path(params[:redirect_to]), allow_other_host: true, notice:, status: :see_other
    elsif was_published
      redirect_back fallback_location: edit_bundle_product_path(@bundle.external_id), notice:, status: :see_other
    else
      redirect_to edit_bundle_content_path(@bundle.external_id), notice:, status: :see_other
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
        :price_currency_type,
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
        :default_offer_code_id,
        refund_policy: [:max_refund_period_in_days, :title],
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

    # Mirrors LinksController#update_default_offer_code so bundles support the
    # "Automatically apply discount code" toggle the same way regular products do.
    def update_default_offer_code
      # Only touch the default offer code when the request includes the field.
      # Requests from flows that don't render the toggle (like converting a
      # product to a bundle) shouldn't silently clear an existing default code.
      return unless params.key?(:default_offer_code_id)

      default_offer_code_id = product_permitted_params[:default_offer_code_id]

      return @bundle.default_offer_code = nil if default_offer_code_id.blank?

      offer_code = @bundle.user.offer_codes.alive.find_by_external_id!(default_offer_code_id)

      # The form re-sends the current id on every save, so a currency change
      # would otherwise be rejected outright by applicable? below. Leave an
      # unchanged id to Link#clear_detached_default_offer_code, which drops it
      # when it stops applying.
      return if offer_code == @bundle.default_offer_code

      raise Link::LinkInvalid, "Offer code cannot be expired" if offer_code.inactive?
      raise Link::LinkInvalid, "Offer code must apply to this product" unless offer_code.applicable?(@bundle)

      @bundle.default_offer_code = offer_code
    rescue ActiveRecord::RecordNotFound
      raise Link::LinkInvalid, "Invalid offer code"
    end
end
