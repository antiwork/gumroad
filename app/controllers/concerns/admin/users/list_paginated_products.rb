# frozen_string_literal: true

module Admin::Users::ListPaginatedProducts
  include Pagy::Backend
  # pagy/extras/standalone may have injected a stub `params` method on this
  # module if the extra was loaded first. Strip it so controllers including
  # this module use ActionController's real `params`.
  remove_method(:params) if instance_methods(false).include?(:params)

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
               user: -> { { external_id: user.external_id } },
               products: products.includes(:ordered_alive_product_files, :active_integrations, :staff_picked_product, :taxonomy).map do |product|
                           Admin::ProductPresenter::Card.new(product:, pundit_user:).props
                         end,
               pagination: PagyPresenter.new(pagination).props
             }
    end
end
