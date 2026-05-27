# frozen_string_literal: true

class CollabProductsPagePresenter
  include ProductsHelper
  include Rails.application.routes.url_helpers

  PER_PAGE = 50

  attr_reader :products_sort, :memberships_sort

  def initialize(pundit_user:, products_page: 1, memberships_page: 1, products_sort: nil, memberships_sort: nil, query: nil)
    @pundit_user = pundit_user
    @products_page = products_page
    @memberships_page = memberships_page
    @products_sort = products_sort
    @memberships_sort = memberships_sort
    @query = query
  end

  def initial_page_props
    build_stats

    {
      stats: {
        total_revenue:,
        total_customers:,
        total_members:,
        total_collaborations:,
      },
      archived_tab_visible: seller.archived_products_count > 0,
      **products_table_props,
      **memberships_table_props,
      collaborators_disabled_reason: seller.has_brazilian_stripe_connect_account? ? "Collaborators with Brazilian Stripe accounts are not supported." : nil,
    }
  end

  def products_table_props
    products_pagination, products = paginated_collabs(for_memberships: false)

    {
      products: products_data(products),
      products_pagination:,
    }
  end

  def memberships_table_props
    memberships_pagination, memberships = paginated_collabs(for_memberships: true)

    {
      memberships: memberships_data(memberships),
      memberships_pagination:,
    }
  end

  private
    attr_reader :pundit_user, :products_page, :memberships_page, :query, :total_revenue, :total_customers, :total_members, :total_collaborations

    def seller
      pundit_user.seller
    end

    def fetch_collabs(only: nil)
      collabs = Link.collabs_as_seller_or_collaborator(seller)
      if only == "memberships"
        collabs = collabs.membership
      elsif only == "products"
        collabs = collabs.non_membership
      end
      collabs = collabs.where("links.name like ?", "%#{query}%") if query.present?
      collabs
    end

    def paginated_collabs(for_memberships:)
      page = for_memberships ? memberships_page : products_page
      sort = for_memberships ? memberships_sort : products_sort
      sort_and_paginate_products(
        key: sort&.dig(:key),
        direction: sort&.dig(:direction),
        page:,
        collection: fetch_collabs(only: for_memberships ? "memberships" : "products"),
        per_page: PER_PAGE,
        user_id: seller.id
      )
    end

    def build_stats
      @total_revenue = 0
      @total_customers = 0
      @total_members = 0
      @total_collaborations = 0

      collabs = fetch_collabs

      collabs.each do |product|
        @total_collaborations += 1 unless product.deleted? || product.archived?
        @total_revenue += product.total_usd_cents_earned_by_user(seller)
        if product.is_recurring_billing?
          @total_members += product.active_customers_count
        else
          @total_customers += product.active_customers_count
        end
      end
    end

    def memberships_data(memberships)
      Product::Caching.dashboard_collection_data(memberships, cache: true) do |membership|
        product_base_data(membership)
      end
    end

    def products_data(products)
      Product::Caching.dashboard_collection_data(products, cache: true) do |product|
        product_base_data(product)
      end
    end

    def product_base_data(product)
      {
        "id" => product.id,
        "edit_url" => edit_link_path(product),
        "name" => product.name,
        "permalink" => product.unique_permalink,
        "price_formatted" => product.price_formatted_including_rental_verbose,
        "revenue" => product.total_usd_cents_earned_by_user(seller),
        "thumbnail" => product.thumbnail&.alive&.as_json,
        "display_price_cents" => product.display_price_cents,
        "url" => product.long_url,
        "url_without_protocol" => product.long_url(include_protocol: false),
        "has_duration" => product.duration_in_months.present?,
        "cut" => product.percentage_revenue_cut_for_user(seller),
        "can_edit" => Pundit.policy!(pundit_user, product).edit?,
      }
    end
end
