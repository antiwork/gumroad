# frozen_string_literal: true

class Purchases::ProductController < ApplicationController
  before_action :set_purchase

  def show
    @purchase_product_presenter = PurchaseProductPresenter.new(@purchase)
    # Ensure that the React component receives the same props as the product page, in case ProductPresenter.product_props
    # changes
    @product_props = ProductPresenter.new(product: @purchase.link, request:, pundit_user:).product_props(seller_custom_domain_url:).deep_merge(@purchase_product_presenter.product_props)
    @user = @purchase_product_presenter.product.user

    @hide_layouts = true
    set_noindex_header
  end
end
