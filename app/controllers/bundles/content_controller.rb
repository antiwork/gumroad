# frozen_string_literal: true

module Bundles
  class ContentController < Sellers::BaseController
    layout "inertia"
    include SearchProducts

    PER_PAGE = 10

    def edit
      bundle = Link.can_be_bundle.find_by_external_id!(params[:bundle_id])
      authorize bundle

      set_meta_tag(title: bundle.name)

      props = BundlePresenter.new(bundle:).bundle_props

      # Only expose props needed for Content tab
      props = props.slice(:bundle, :id, :unique_permalink, :currency_type, :products_count, :has_outdated_purchases)

      # Load products for search if needed
      if params[:query].present? || params[:load_products]
        props[:available_products] = load_available_products(bundle)
      end

      render inertia: "Bundles/Content/Edit", props:
    end

    def update
      bundle = Link.can_be_bundle.find_by_external_id!(params[:bundle_id])
      authorize bundle

      begin
        bundle.is_bundle = true
        bundle.native_type = Link::NATIVE_TYPE_BUNDLE

        # Update bundle products
        update_bundle_products(bundle, content_permitted_params[:products]) if content_permitted_params[:products]

        bundle.save!
      rescue ActiveRecord::RecordNotSaved, ActiveRecord::RecordInvalid, Link::LinkInvalid => e
        error_message = bundle.errors.full_messages.first || e.message
        return redirect_back fallback_location: edit_bundles_content_path(params[:bundle_id]),
                             inertia: { errors: { base: error_message } }
      end

      redirect_to edit_bundles_content_path(params[:bundle_id]), notice: "Changes saved!"
    end

    private

    def content_permitted_params
      params.permit(products: [:product_id, :variant_id, :quantity, :position])
    end

    def load_available_products(bundle)
      options = {
        query: params[:query],
        from: params[:from],
        sort: ProductSortKey::FEATURED,
        user_id: current_seller.id,
        is_subscription: false,
        is_bundle: false,
        is_alive: true,
        is_call: false,
        exclude_ids: [bundle.id],
      }
      options[:size] = PER_PAGE unless params[:all] == "true"

      search_products(options)[:products].map { BundlePresenter.bundle_product(product: _1) }
    end

    def update_bundle_products(bundle, new_bundle_products)
      return unless new_bundle_products

      bundle_products = bundle.bundle_products.includes(:product)

      bundle_products.each do |bundle_product|
        new_bundle_product = new_bundle_products.find { _1[:product_id] == bundle_product.product.external_id }
        if new_bundle_product.present?
          bundle_product.update(
            variant: BaseVariant.find_by_external_id(new_bundle_product[:variant_id]),
            quantity: new_bundle_product[:quantity],
            deleted_at: nil,
            position: new_bundle_product[:position]
          )
          new_bundle_products.delete(new_bundle_product)
          update_has_outdated_purchases(bundle)
        else
          bundle_product.mark_deleted!
        end
      end

      update_has_outdated_purchases(bundle) if new_bundle_products.present?

      new_bundle_products.each do |new_bundle_product|
        product = Link.find_by_external_id!(new_bundle_product[:product_id])
        variant = BaseVariant.find_by_external_id(new_bundle_product[:variant_id])

        bundle.bundle_products.create!(
          product:,
          variant:,
          quantity: new_bundle_product[:quantity],
          position: new_bundle_product[:position]
        )
      end
    end

    def update_has_outdated_purchases(bundle)
      return if bundle.has_outdated_purchases?

      bundle.has_outdated_purchases = true if bundle.successful_sales_count > 0
    end
  end
end
