# frozen_string_literal: true

class Products::MobileTrackingController < ApplicationController
  before_action :hide_layouts

  def show
    product = Link.fetch(params[:link_id])
    @tracking_props = MobileTrackingPresenter.new(seller: product.user).product_props(product:)
    @tracking_props[:enabled] = analytics_enabled?(seller: product.user)
  end
end
