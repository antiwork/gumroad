# frozen_string_literal: true

module Admin::Users::ListPaginatedProducts
  include Pagy::Backend

  PRODUCTS_ORDER = Arel.sql("ISNULL(COALESCE(purchase_disabled_at, banned_at, links.deleted_at)) DESC, created_at DESC")
  PRODUCTS_PER_PAGE = 10

  private
    def list_paginated_products(user:, products:, inertia_template:)
      pagination, products = pagy(
        products.order(PRODUCTS_ORDER),
        page: params[:page],
        limit: params[:per_page] || PRODUCTS_PER_PAGE,
      )

      render inertia: inertia_template,
             props: {
               user: -> { { id: user.id } },
               products: products.includes(:ordered_alive_product_files, :active_integrations, :staff_picked_product, :taxonomy).map do |product|
                           Admin::ProductPresenter::Card.new(
                             product:,
                             admins_can_mark_as_staff_picked: ->(product) { policy([:admin, :products, :staff_picked, product]).create? },
                             admins_can_unmark_as_staff_picked: ->(product) { policy([:admin, :products, :staff_picked, product]).destroy? }
                           ).props
                         end,
               pagination: PagyPresenter.new(pagination).props
             }
    end
end
