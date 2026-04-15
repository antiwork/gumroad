# frozen_string_literal: true

class BundlesController < Sellers::BaseController
  include Product::BundlesMarketing

  def show
    bundle = Link.can_be_bundle.find_by_external_id!(params[:id])
    authorize bundle

    redirect_to edit_bundle_product_path(bundle.external_id), status: :moved_permanently
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

    redirect_to edit_bundle_product_path(bundle.external_id)
  end

  private
    def create_from_email_permitted_params
      params.permit(:type, :price, products: [])
    end
end
