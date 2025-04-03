# frozen_string_literal: true

class DashboardProductsPagePresenter
  include Product::Caching
  include ActionView::Helpers::NumberHelper
  include ActionView::Helpers::TextHelper
  include Rails.application.routes.url_helpers

  attr_reader :memberships, :memberships_pagination, :products, :products_pagination, :pundit_user

  def initialize(pundit_user:, memberships:, memberships_pagination:, products:, products_pagination:)
    @pundit_user = pundit_user
    @memberships = memberships
    @memberships_pagination = memberships_pagination
    @products = products
    @products_pagination = products_pagination
  end

  def page_props
    {
      memberships: memberships_data,
      memberships_pagination:,
      products: products_data,
      products_pagination:,
      archived_products_count: @pundit_user.seller.archived_products_count,
      can_create_product: Pundit.policy!(@pundit_user, Link).create?,
    }
  end

  def memberships_table_props
    {
      memberships: memberships_data,
      memberships_pagination:,
    }
  end

  def products_table_props
    {
      products: products_data,
      products_pagination:,
    }
  end

  private
    def memberships_data
      Product::Caching.dashboard_collection_data(memberships, cache: true) do |membership|
        product_base_data(membership, pundit_user:)
      end
    end

    def products_data
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
