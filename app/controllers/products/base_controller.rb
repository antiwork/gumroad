# frozen_string_literal: true

class Products::BaseController < Sellers::BaseController
  layout "inertia"

  before_action :set_product
  before_action :authorize_product
  before_action :set_default_page_title

  protected
    def set_product
      @product = Link.find_by!(unique_permalink: params[:product_id] || params[:id])
    end

    def authorize_product
      authorize @product
    end

    def set_default_page_title
      set_meta_tag(title: @product.name)
    end

    def presenter
      @presenter ||= ProductPresenter.new(product: @product, pundit_user:)
    end
end
