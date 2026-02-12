# frozen_string_literal: true

class Purchases::ProductController < ApplicationController
  layout "inertia"
  before_action :set_purchase

  def show
    purchase_product_presenter = PurchaseProductPresenter.new(@purchase)
    # Ensure that the React component receives the same props as the product page, in case ProductPresenter.product_props
    # changes
    product_props = ProductPresenter.new(product: @purchase.link, request:, pundit_user:).product_props(seller_custom_domain_url:).deep_merge(purchase_product_presenter.product_props)
    product_props = product_props.merge(custom_styles: purchase_product_presenter.product.user.seller_profile.custom_styles.to_s)

    set_noindex_header
    render inertia: "Purchases/Product/Show", props: product_props
  end
end
