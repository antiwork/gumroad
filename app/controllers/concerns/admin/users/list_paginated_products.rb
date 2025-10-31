# frozen_string_literal: true

module Admin::Users::ListPaginatedProducts
  include Pagy::Backend

  PRODUCTS_ORDER = "ISNULL(COALESCE(purchase_disabled_at, banned_at, links.deleted_at)) DESC, created_at DESC"
  PRODUCTS_PER_PAGE = 10

  private
    def list_paginated_products(user:, products:, inertia_template:)
      pagination, products = pagy(
        products.order(Arel.sql(PRODUCTS_ORDER)),
        page: params[:page],
        limit: params[:per_page] || PRODUCTS_PER_PAGE,
      )

      render inertia: inertia_template,
             props: {
               user: -> { Admin::UserPresenter::Card.new(
                 user:,
                 impersonatable: policy([:admin, :impersonators, user]).create?
               ).props },
               products: products.includes(:ordered_alive_product_files, :active_integrations).map do |product|
                           product.as_json(
                             admin: true,
                             admins_can_mark_as_staff_picked: ->(product) { policy([:admin, :products, :staff_picked, product]).create? },
                             admins_can_unmark_as_staff_picked: ->(product) { policy([:admin, :products, :staff_picked, product]).destroy? }
                            )
                         end,
               pagination: PagyPresenter.new(pagination).props
             }
    end
end
