# frozen_string_literal: true

class DashboardProductsPagePresenter
  include Product::Caching
  include ProductsHelper
  include ActionView::Helpers::NumberHelper
  include ActionView::Helpers::TextHelper
  include Rails.application.routes.url_helpers

  PER_PAGE = 50

  attr_reader :products_sort, :memberships_sort

  def initialize(pundit_user:, archived: false, products_page: 1, memberships_page: 1, products_sort: nil, memberships_sort: nil, query: nil)
    @pundit_user = pundit_user
    @archived = archived
    @products_page = products_page
    @memberships_page = memberships_page
    @products_sort = products_sort
    @memberships_sort = memberships_sort
    @query = query
  end

  def empty?
    return nil unless archived?
    products_table_props[:products].empty? && memberships_table_props[:memberships].empty?
  end

  def page_props
    @page_props ||= if archived?
      { can_create_product: Pundit.policy!(@pundit_user, Link).create? }
    else
      {
        archived_products_count: seller.archived_products_count,
        can_create_product: Pundit.policy!(@pundit_user, Link).create?,
      }
    end
  end

  def memberships_table_props
    @memberships_table_props ||= begin
      memberships_pagination, memberships = paginated_memberships

      {
        memberships: memberships_data(memberships),
        memberships_pagination:,
      }
    end
  end

  def products_table_props
    @products_table_props ||= begin
      products_pagination, products = paginated_products

      {
        products: products_data(products),
        products_pagination:,
      }
    end
  end

  def product_props(product)
    product_base_data(product, pundit_user:)
  end

  private
    attr_reader :pundit_user, :products_page, :memberships_page, :query

    def archived? = @archived

    def seller
      pundit_user.seller
    end

    def paginated_memberships
      memberships = seller.products.membership.visible
      memberships = archived? ? memberships.archived : memberships.not_archived
      memberships = memberships.where("name like ?", "%#{query}%") if query.present?

      sort_and_paginate_products(
        key: memberships_sort&.dig(:key),
        direction: memberships_sort&.dig(:direction),
        page: memberships_page,
        collection: memberships,
        per_page: PER_PAGE,
        user_id: seller.id
      )
    end

    def paginated_products
      products = seller
        .products
        .includes([
                    thumbnail: { file_attachment: { blob: { variant_records: { image_attachment: :blob } } } },
                    thumbnail_alive: { file_attachment: { blob: { variant_records: { image_attachment: :blob } } } },
                  ])
        .non_membership
        .visible
      products = archived? ? products.archived : products.not_archived
      products = products.where("links.name like ?", "%#{query}%") if query.present?

      sort_and_paginate_products(
        key: products_sort&.dig(:key),
        direction: products_sort&.dig(:direction),
        page: products_page,
        collection: products,
        per_page: PER_PAGE,
        user_id: seller.id
      )
    end

    def memberships_data(memberships)
      Product::Caching.dashboard_collection_data(memberships, cache: true) do |membership|
        product_base_data(membership, pundit_user:)
      end
    end

    def products_data(products)
      Product::Caching.dashboard_collection_data(products, cache: true) do |product|
        product_base_data(product, pundit_user:)
      end
    end

    def product_base_data(product, pundit_user:)
      {
        "id" => product.id,
        "edit_url" => edit_link_path(product),
        "is_duplicating" => product.is_duplicating?,
        "is_unpublished" => product.draft? || product.purchase_disabled_at?,
        "name" => product.name,
        "permalink" => product.unique_permalink,
        "price_formatted" => product.price_formatted_including_rental_verbose,
        "revenue" => product.total_usd_cents,
        "status" => product_status(product),
        "thumbnail" => product.thumbnail&.alive&.as_json,
        "display_price_cents" => product.display_price_cents,
        "url" => product.long_url,
        "url_without_protocol" => product.long_url(include_protocol: false),
        "has_duration" => product.duration_in_months.present?,
        "can_edit" => Pundit.policy!(pundit_user, product).edit?,
        "can_destroy" => Pundit.policy!(pundit_user, product).destroy?,
        "can_duplicate" => Pundit.policy!(pundit_user, [:product_duplicates, product]).create?,
        "can_archive" => Pundit.policy!(pundit_user, [:products, :archived, product]).create?,
        "can_unarchive" => Pundit.policy!(pundit_user, [:products, :archived, product]).destroy?,
      }
    end

    def product_status(product)
      if product.draft? || product.purchase_disabled_at?
        "unpublished"
      elsif product.is_in_preorder_state?
        "preorder"
      else
        "published"
      end
    end
end
