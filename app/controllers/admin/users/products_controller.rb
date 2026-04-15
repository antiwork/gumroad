# frozen_string_literal: true

class Admin::Users::ProductsController < Admin::Users::BaseController
  include Admin::Users::ListPaginatedProducts

  before_action :fetch_user

  def index
    set_meta_tag(title: "#{@user.display_name} products on Gumroad")

    list_paginated_products user: @user,
                            products: @user.products,
                            inertia_template: "Admin/Users/Products/Index"
  end
end
