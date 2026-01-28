# frozen_string_literal: true

class Purchases::ProductController < ApplicationController
  before_action :set_purchase

  layout "inertia"

  def show
    purchase_product_presenter = PurchaseProductPresenter.new(@purchase)
    # Ensure that the React component receives the same props as the product page, in case ProductPresenter.product_props
    # changes
    product_props = ProductPresenter.new(product: @purchase.link, request:, pundit_user:).product_props(seller_custom_domain_url:).deep_merge(purchase_product_presenter.product_props)
    user = purchase_product_presenter.product.user

    set_noindex_header

    render inertia: "Purchases/ProductPage", props: {
      **product_props,
      custom_styles: user.seller_profile.custom_styles
    }
  end
end
