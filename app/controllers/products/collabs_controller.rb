# frozen_string_literal: true

class Products::CollabsController < Sellers::BaseController
  before_action :authorize

  layout "inertia"

  def index
    set_meta_tag(title: "Products")
    presenter = CollabProductsPagePresenter.new(
      pundit_user:,
      query: collabs_params[:query],
      products_page: collabs_params[:products_page],
      products_sort: collabs_params[:products_sort],
      memberships_page: collabs_params[:memberships_page],
      memberships_sort: collabs_params[:memberships_sort]
    )

    render inertia: "Products/Collabs/Index", props: {
      stats: -> { presenter.initial_page_props[:stats] },
      archived_tab_visible: -> { presenter.initial_page_props[:archived_tab_visible] },
      collaborators_disabled_reason: -> { presenter.initial_page_props[:collaborators_disabled_reason] },
      products_data: -> {
        {
          products: presenter.products_table_props[:products],
          pagination: presenter.products_table_props[:products_pagination],
          sort: presenter.products_sort,
        }
      },
      memberships_data: -> {
        {
          memberships: presenter.memberships_table_props[:memberships],
          pagination: presenter.memberships_table_props[:memberships_pagination],
          sort: presenter.memberships_sort,
        }
      },
    }
  end

  private
    def authorize
      super([:products, :collabs])
    end

    def collabs_params
      @collabs_params ||= begin
        permitted = params.permit(
          :query, :products_page, :memberships_page,
          :products_sort_key, :products_sort_direction,
          :memberships_sort_key, :memberships_sort_direction
        )

        {
          query: permitted[:query],
          products_page: permitted[:products_page],
          products_sort: extract_sort_params(:products, permitted),
          memberships_page: permitted[:memberships_page],
          memberships_sort: extract_sort_params(:memberships, permitted)
        }
      end
    end

    def extract_sort_params(prefix, permitted)
      key = permitted[:"#{prefix}_sort_key"]
      direction = permitted[:"#{prefix}_sort_direction"]
      return nil unless %w[name display_price_cents cut successful_sales_count revenue].include?(key)
      { key:, direction: direction == "desc" ? "desc" : "asc" }
    end
end
