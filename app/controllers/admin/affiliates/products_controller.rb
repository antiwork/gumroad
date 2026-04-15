# frozen_string_literal: true

class Admin::Affiliates::ProductsController < Admin::Affiliates::BaseController
  include Admin::Users::ListPaginatedProducts

  def index
    set_meta_tag(title: "#{@affiliate_user.display_name} products on Gumroad")

    list_paginated_products user: @affiliate_user,
                            products: @affiliate_user.directly_affiliated_products.unscope(where: :purchase_disabled_at).order(Admin::Users::ListPaginatedProducts::PRODUCTS_ORDER),
                            inertia_template: "Admin/Affiliates/Products/Index"
  end
end
