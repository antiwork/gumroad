# frozen_string_literal: true

class BundlesController < Sellers::BaseController
  include SearchProducts, Product::BundlesMarketing

  PER_PAGE = 10

  def show
    bundle = Link.can_be_bundle.find_by_external_id!(params[:id])

    authorize bundle

    @title = bundle.name

    @props = BundlePresenter.new(bundle:).bundle_props
  end

  def create_from_email
    authorize Link, :create?

    bundle = current_seller.products.build(
      name: BUNDLE_NAMES[create_from_email_permitted_params[:type]],
      is_bundle: true,
      native_type: Link::NATIVE_TYPE_BUNDLE,
      price_cents: create_from_email_permitted_params[:price],
      price_currency_type: current_seller.currency_type,
      from_bundle_marketing: true,
      draft: true,
    )
    products = current_seller.products.by_external_ids(create_from_email_permitted_params[:products])
    products.each do |product|
      bundle.bundle_products.build(bundle:, product:, variant: product.alive_variants.first, quantity: 1)
    end
    bundle.save!

    redirect_to bundle_path(bundle.external_id)
  end

  def products
    authorize Link, :index?

    options = {
      query: products_permitted_params[:query],
      from: products_permitted_params[:from],
      sort: ProductSortKey::FEATURED,
      user_id: current_seller.id,
      is_subscription: false,
      is_bundle: false,
      is_alive: true,
      is_call: false,
      exclude_ids: [ObfuscateIds.decrypt(products_permitted_params[:product_id])],
    }
    options[:size] = PER_PAGE unless products_permitted_params[:all] == "true"

    products = search_products(options)[:products].map { BundlePresenter.bundle_product(product: _1) }

    render json: { products: }
  end

  def update_purchases_content
    @bundle = Link.is_bundle.find_by_external_id!(params[:id])

    authorize @bundle, :update?

    return render json: { error: "This bundle has no purchases with outdated content." }, status: :forbidden unless @bundle.has_outdated_purchases?

    UpdateBundlePurchasesContentJob.perform_async(@bundle.id)

    head :no_content
  end

  def update
    @bundle = Link.can_be_bundle.find_by_external_id!(params[:id])

    authorize @bundle

    begin
      @bundle.is_bundle = true
      @bundle.native_type = Link::NATIVE_TYPE_BUNDLE
      @bundle.assign_attributes(bundle_permitted_params.except(
        :products, :custom_button_text_option, :custom_summary, :custom_attributes, :tags, :covers, :refund_policy, :product_refund_policy_enabled,
        :seller_refund_policy_enabled, :section_ids, :installment_plan)
      )
      @bundle.save_custom_button_text_option(bundle_permitted_params[:custom_button_text_option]) unless bundle_permitted_params[:custom_button_text_option].nil?
      @bundle.save_custom_summary(bundle_permitted_params[:custom_summary]) unless bundle_permitted_params[:custom_summary].nil?
      @bundle.save_custom_attributes(bundle_permitted_params[:custom_attributes]) unless bundle_permitted_params[:custom_attributes].nil?
      @bundle.save_tags!(bundle_permitted_params[:tags]) unless bundle_permitted_params[:tags].nil?
      @bundle.reorder_previews(bundle_permitted_params[:covers].map.with_index.to_h) if bundle_permitted_params[:covers].present?
      if !current_seller.account_level_refund_policy_enabled?
        @bundle.product_refund_policy_enabled = bundle_permitted_params[:product_refund_policy_enabled]
        if bundle_permitted_params[:refund_policy].present? && bundle_permitted_params[:product_refund_policy_enabled]
          @bundle.find_or_initialize_product_refund_policy.update!(bundle_permitted_params[:refund_policy])
        end
      end
      @bundle.show_in_sections!(bundle_permitted_params[:section_ids]) if bundle_permitted_params[:section_ids]

      update_installment_plan
      update_bundle_products(bundle_permitted_params[:products]) unless bundle_permitted_params[:products].nil?
      @bundle.save!
    rescue ActiveRecord::RecordNotSaved, ActiveRecord::RecordInvalid, Link::LinkInvalid => e
      error_message = @bundle.errors.full_messages.first || e.message
      return render json: { error_message: }, status: :unprocessable_entity
    end

    head :no_content
  end

  private
    def bundle_permitted_params
      params.permit(policy(@bundle).bundle_permitted_attributes)
    end

    def create_from_email_permitted_params
      params.permit(:type, :price, products: [])
    end

    def products_permitted_params
      params.permit(:query, :from, :all, :product_id)
    end

    def update_bundle_products(new_bundle_products)
      bundle_products = @bundle.bundle_products.includes(:product)

      bundle_products.each do |bundle_product|
        new_bundle_product = new_bundle_products.find { _1[:product_id] == bundle_product.product.external_id }
        if new_bundle_product.present?
          bundle_product.update(variant: BaseVariant.find_by_external_id(new_bundle_product[:variant_id]), quantity: new_bundle_product[:quantity], deleted_at: nil, position: new_bundle_product[:position])
          new_bundle_products.delete(new_bundle_product)
          update_has_outdated_purchases
        else
          bundle_product.mark_deleted!
        end
      end

      update_has_outdated_purchases if new_bundle_products.present?

      new_bundle_products.each do |new_bundle_product|
        product = Link.find_by_external_id!(new_bundle_product[:product_id])
        variant = BaseVariant.find_by_external_id(new_bundle_product[:variant_id])

        @bundle.bundle_products.create!(product:, variant:, quantity: new_bundle_product[:quantity], position: new_bundle_product[:position])
      end
    end

    def update_has_outdated_purchases
      return if @bundle.has_outdated_purchases?

      @bundle.has_outdated_purchases = true if @bundle.successful_sales_count > 0
    end

    def update_installment_plan
      return unless @bundle.eligible_for_installment_plans?

      if @bundle.installment_plan && bundle_permitted_params[:installment_plan].present?
        @bundle.installment_plan.assign_attributes(bundle_permitted_params[:installment_plan])
        return unless @bundle.installment_plan.changed?
      end

      @bundle.installment_plan&.destroy_if_no_payment_options!
      @bundle.reset_installment_plan

      if bundle_permitted_params[:installment_plan].present?
        @bundle.create_installment_plan!(bundle_permitted_params[:installment_plan])
      end
    end
end
