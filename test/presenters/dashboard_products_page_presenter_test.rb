# frozen_string_literal: true

require "test_helper"

# Ported from spec/presenters/dashboard_products_page_presenter_spec.rb (#5801).
#
# The presenter behind the seller's Products dashboard (and its archived
# variant). Three groups of behavior, split into three test classes because
# only one of them needs a real Elasticsearch cluster:
#
#   * DashboardProductsPagePresenterTest — scoping, prop shape, permissions,
#     pagination, #empty?. All SQL, so the stubbed Elasticsearch client the
#     harness installs process-wide is fine.
#   * DashboardProductsPagePresenterCachingTest — the ProductCachedValue write
#     path, which runs CacheProductDataWorker inline.
#   * DashboardProductsPagePresenterSortingTest — sorting. Two of the sort keys
#     (display_price_cents, is_recommendable) are served by Elasticsearch rather
#     than SQL (Product::Sorting::ES_SORT_KEYS), and the sales/revenue keys read
#     ProductCachedValue rows whose values come from purchase aggregations, so
#     this class swaps in the real client via RealElasticsearchBridge.
#
# The spec shrank DashboardProductsPagePresenter::PER_PAGE from 50 to 2 with
# RSpec's stub_const so that a handful of products spans several pages; the
# Minitest equivalent is with_const_on (test/support/constant_stubbing_helpers).
class DashboardProductsPagePresenterTest < ActiveSupport::TestCase
  # Route helpers come from ModelFactories#routes, NOT from
  # `include Rails.application.routes.url_helpers` — that include defines
  # `test_pings_path`/`test_pings_url` (config/routes.rb has a test_pings
  # resource), and Minitest runs every method matching /^test_/ as a test, so
  # the class silently gains two always-passing zero-assertion tests.

  setup do
    @seller = users(:named_seller)
    # The shared fixture set gives the standard seller one product
    # (links(:product), with a purchase hanging off it). Every test here starts
    # from "this seller's dashboard shows exactly the products I just created",
    # so take the fixture product out of the dashboard's scope first. Soft-delete
    # rather than destroy so the fixture purchase keeps its product, and
    # update_columns so no callback tries to touch the search index.
    links(:product).update_columns(deleted_at: Time.current)
    # The spec created marketing/support team members for the seller; the
    # fixture set already has one user per role, so use those.
    @marketing_for_seller = users(:marketing_for_named_seller)
    @support_for_seller = users(:support_for_named_seller)
    @pundit_user = SellerContext.new(user: @marketing_for_seller, seller: @seller)
    @read_only_pundit_user = SellerContext.new(user: @support_for_seller, seller: @seller)
  end

  def presenter(**args)
    DashboardProductsPagePresenter.new(pundit_user: @pundit_user, **args)
  end

  # Shrink the page size so a 5-product fixture spans 3 pages, the way the spec
  # did with stub_const.
  def with_page_size(size, &block)
    with_const_on(DashboardProductsPagePresenter, :PER_PAGE, size, &block)
  end

  # Compare the props the presenter built against an expected hash, restricted to
  # the keys the expectation names. Written as one hash comparison rather than a
  # per-key assertion so a failure prints the whole diff, and restricted to the
  # named keys so it stays an `include`-style check (the spec used RSpec's
  # `include` matcher) instead of breaking every time a new prop is added.
  def assert_props(expected, actual)
    assert_equal expected, actual.slice(*expected.keys)
  end

  # --- #page_props -----------------------------------------------------------

  test "#page_props reports no products and the archived count when every product is archived" do
    create_product(user: @seller, archived: true)

    props = presenter.page_props

    assert_equal false, props[:has_products].call
    assert_equal 1, props[:archived_products_count].call
    assert_equal true, props[:can_create_product].call
  end

  test "#page_props reports has_products when the seller has a visible non-archived product" do
    create_product(user: @seller, archived: true)
    create_product(user: @seller, name: "Active product")

    assert_equal true, presenter.page_props[:has_products].call
  end

  test "#page_props keeps has_products true when the search query matches nothing" do
    create_product(user: @seller, archived: true)
    create_product(user: @seller, name: "Active product")

    assert_equal true, presenter(query: "no-match").page_props[:has_products].call
  end

  # --- #products_table_props -------------------------------------------------

  test "#products_table_props returns only the seller's visible non-archived products" do
    create_product(user: @seller, name: "normal_product", price_cents: 1000)
    create_product(user: @seller, name: "archived_product", archived: true)
    create_product(user: @seller, name: "deleted_product", deleted_at: Time.current)
    create_product(name: "other_product")

    names = presenter.products_table_props[:products].map { |product| product["name"] }

    assert_includes names, "normal_product"
    assert_not_includes names, "archived_product"
    assert_not_includes names, "deleted_product"
    assert_not_includes names, "other_product"
  end

  test "#products_table_props returns the full prop shape for a product" do
    product = create_product(user: @seller, name: "normal_product", price_cents: 1000)

    assert_props({
                   "id" => product.id,
                   "name" => "normal_product",
                   "edit_url" => routes.edit_link_path(product),
                   "is_duplicating" => false,
                   "is_unpublished" => false,
                   "permalink" => product.unique_permalink,
                   "price_formatted" => product.price_formatted_including_rental_verbose,
                   "revenue" => product.total_usd_cents,
                   "status" => "published",
                   "thumbnail" => nil,
                   "display_price_cents" => product.display_price_cents,
                   "url" => product.long_url,
                   "url_without_protocol" => product.long_url(include_protocol: false),
                   "has_duration" => false,
                   "successful_sales_count" => product.successful_sales_count,
                   "remaining_for_sale_count" => product.remaining_for_sale_count,
                   "monthly_recurring_revenue" => product.monthly_recurring_revenue.to_f,
                   "revenue_pending" => product.revenue_pending.to_f,
                   "can_edit" => true,
                   "can_destroy" => true,
                   "can_duplicate" => true,
                   "can_archive" => true,
                   "can_unarchive" => false,
                 }, presenter.products_table_props[:products].sole)
  end

  test "#products_table_props filters products by the search query" do
    create_product(user: @seller, name: "normal_product")
    create_product(user: @seller, name: "another_product")

    names = presenter(query: "another").products_table_props[:products].map { |product| product["name"] }

    assert_includes names, "another_product"
    assert_not_includes names, "normal_product"
  end

  test "#products_table_props returns nothing for a query that matches no product" do
    create_product(user: @seller, name: "normal_product")

    assert_empty presenter(query: "nonexistent_xyz").products_table_props[:products]
  end

  test "paginates the lean product relation without eager-loading thumbnails into it (GUMROAD-1AS)" do
    create_product(user: @seller, name: "p")

    paginated_collection = nil
    presenter = self.presenter
    presenter.stub(:sort_and_paginate_products, ->(**kwargs) {
      paginated_collection = kwargs[:collection]
      [{ page: 1, pages: 1 }, []]
    }) do
      presenter.send(:paginated_products)
    end

    assert_not_nil paginated_collection
    # The thumbnail chain must be preloaded AFTER pagination, never eager-loaded
    # into the paginated relation. `includes` here turns into an 11-way LEFT JOIN
    # over a large catalogue and times the request out (GUMROAD-1AS, 73s span).
    assert_empty paginated_collection.includes_values
    assert_empty paginated_collection.eager_load_values
  end

  test "page products still render their thumbnail via the post-pagination preload (GUMROAD-1AS)" do
    product = create_product(user: @seller, name: "thumbnailed_product")
    create_thumbnail(product:)

    thumbnail_prop = presenter.products_table_props[:products].sole["thumbnail"]

    assert thumbnail_prop.present?, "expected the page product's thumbnail to be preloaded and rendered"
    assert_equal product.thumbnail.alive.as_json, thumbnail_prop
  end

  test "#products_table_props denies every product action for a read-only team member" do
    create_product(user: @seller, name: "normal_product")

    assert_props({
                   "can_edit" => false,
                   "can_destroy" => false,
                   "can_duplicate" => false,
                   "can_archive" => false,
                   "can_unarchive" => false,
                 }, DashboardProductsPagePresenter.new(pundit_user: @read_only_pundit_user).products_table_props[:products].sole)
  end

  # --- #memberships_table_props ----------------------------------------------

  test "#memberships_table_props returns only the seller's visible non-archived memberships" do
    create_membership_product(user: @seller, name: "normal_membership")
    create_membership_product(user: @seller, name: "archived_membership", archived: true)
    create_membership_product(user: @seller, name: "deleted_membership", deleted_at: Time.current)
    create_membership_product(name: "other_membership")

    names = presenter.memberships_table_props[:memberships].map { |membership| membership["name"] }

    assert_includes names, "normal_membership"
    assert_not_includes names, "archived_membership"
    assert_not_includes names, "deleted_membership"
    assert_not_includes names, "other_membership"
  end

  test "#memberships_table_props returns the full prop shape for a membership" do
    membership = create_membership_product(user: @seller, name: "normal_membership")

    assert_props({
                   "id" => membership.id,
                   "name" => "normal_membership",
                   "edit_url" => routes.edit_link_path(membership),
                   "is_duplicating" => false,
                   "is_unpublished" => false,
                   "permalink" => membership.unique_permalink,
                   "price_formatted" => membership.price_formatted_including_rental_verbose,
                   "revenue" => membership.total_usd_cents,
                   "status" => "published",
                   "thumbnail" => nil,
                   "display_price_cents" => membership.display_price_cents,
                   "url" => membership.long_url,
                   "url_without_protocol" => membership.long_url(include_protocol: false),
                   "has_duration" => membership.duration_in_months.present?,
                   "successful_sales_count" => membership.successful_sales_count,
                   "remaining_for_sale_count" => membership.remaining_for_sale_count,
                   "monthly_recurring_revenue" => membership.monthly_recurring_revenue.to_f,
                   "revenue_pending" => membership.revenue_pending.to_f,
                   "can_edit" => true,
                   "can_destroy" => true,
                   "can_duplicate" => true,
                   "can_archive" => true,
                   "can_unarchive" => false,
                 }, presenter.memberships_table_props[:memberships].sole)
  end

  test "#memberships_table_props filters memberships by the search query" do
    create_membership_product(user: @seller, name: "normal_membership")
    create_membership_product(user: @seller, name: "another_membership")

    names = presenter(query: "another").memberships_table_props[:memberships].map { |membership| membership["name"] }

    assert_includes names, "another_membership"
    assert_not_includes names, "normal_membership"
  end

  test "#memberships_table_props returns nothing for a query that matches no membership" do
    create_membership_product(user: @seller, name: "normal_membership")

    assert_empty presenter(query: "nonexistent_xyz").memberships_table_props[:memberships]
  end

  test "#memberships_table_props denies every membership action for a read-only team member" do
    create_membership_product(user: @seller, name: "normal_membership")

    assert_props({
                   "can_edit" => false,
                   "can_destroy" => false,
                   "can_duplicate" => false,
                   "can_archive" => false,
                   "can_unarchive" => false,
                 }, DashboardProductsPagePresenter.new(pundit_user: @read_only_pundit_user).memberships_table_props[:memberships].sole)
  end

  # --- products pagination ---------------------------------------------------

  test "products pagination returns one page of products with the page count" do
    create_list(:product, 5, user: @seller)

    with_page_size(2) do
      props = presenter(products_page: 1).products_table_props

      assert_equal 2, props[:products].length
      assert_equal({ page: 1, pages: 3 }, props[:products_pagination])
    end
  end

  test "products pagination returns disjoint pages covering the seller's products" do
    products = create_list(:product, 5, user: @seller)

    with_page_size(2) do
      page1 = presenter(products_page: 1).products_table_props
      page2 = presenter(products_page: 2).products_table_props

      assert_equal({ page: 1, pages: 3 }, page1[:products_pagination])
      assert_equal({ page: 2, pages: 3 }, page2[:products_pagination])

      page1_ids = page1[:products].map { |product| product["id"] }
      page2_ids = page2[:products].map { |product| product["id"] }
      assert_empty page1_ids & page2_ids
      assert_empty (page1_ids + page2_ids) - products.map(&:id)
    end
  end

  test "products pagination clamps a page past the end to the last page" do
    create_list(:product, 5, user: @seller)

    with_page_size(2) do
      props = presenter(products_page: 10).products_table_props

      assert_equal({ page: 3, pages: 3 }, props[:products_pagination])
    end
  end

  test "products pagination counts only visible products" do
    products = create_list(:product, 5, user: @seller)
    products.first(2).each { |product| product.update!(deleted_at: Time.current) }

    with_page_size(2) do
      props = presenter(products_page: 1).products_table_props

      assert_equal 2, props[:products].length
      assert_equal({ page: 1, pages: 2 }, props[:products_pagination])
    end
  end

  # --- memberships pagination ------------------------------------------------

  test "memberships pagination returns one page of memberships with the page count" do
    create_list(:membership_product, 5, user: @seller)

    with_page_size(2) do
      props = presenter(memberships_page: 1).memberships_table_props

      assert_equal 2, props[:memberships].length
      assert_equal({ page: 1, pages: 3 }, props[:memberships_pagination])
    end
  end

  test "memberships pagination returns disjoint pages covering the seller's memberships" do
    memberships = create_list(:membership_product, 5, user: @seller)

    with_page_size(2) do
      page1 = presenter(memberships_page: 1).memberships_table_props
      page2 = presenter(memberships_page: 2).memberships_table_props

      assert_equal({ page: 1, pages: 3 }, page1[:memberships_pagination])
      assert_equal({ page: 2, pages: 3 }, page2[:memberships_pagination])

      page1_ids = page1[:memberships].map { |membership| membership["id"] }
      page2_ids = page2[:memberships].map { |membership| membership["id"] }
      assert_empty page1_ids & page2_ids
      assert_empty (page1_ids + page2_ids) - memberships.map(&:id)
    end
  end

  test "memberships pagination clamps a page past the end to the last page" do
    create_list(:membership_product, 5, user: @seller)

    with_page_size(2) do
      props = presenter(memberships_page: 10).memberships_table_props

      assert_equal({ page: 3, pages: 3 }, props[:memberships_pagination])
    end
  end

  test "memberships pagination counts only visible memberships" do
    memberships = create_list(:membership_product, 5, user: @seller)
    memberships.first(2).each { |membership| membership.update!(deleted_at: Time.current) }

    with_page_size(2) do
      props = presenter(memberships_page: 1).memberships_table_props

      assert_equal 2, props[:memberships].length
      assert_equal({ page: 1, pages: 2 }, props[:memberships_pagination])
    end
  end

  # --- #empty? ---------------------------------------------------------------

  test "#empty? is nil when not looking at the archived page" do
    assert_nil presenter.empty?
  end

  # --- archived: true --------------------------------------------------------

  test "#empty? is true when the seller has no archived products or memberships" do
    create_product(user: @seller)
    create_membership_product(user: @seller)

    assert_equal true, presenter(archived: true).empty?
  end

  test "#empty? is false when the seller has an archived product" do
    create_product(user: @seller, archived: true)

    assert_equal false, presenter(archived: true).empty?
  end

  test "#empty? is false when the seller has an archived membership" do
    create_membership_product(user: @seller, archived: true)

    assert_equal false, presenter(archived: true).empty?
  end

  test "#empty? is true when the only archived product is deleted" do
    create_product(user: @seller, archived: true, deleted_at: Time.current)

    assert_equal true, presenter(archived: true).empty?
  end

  test "#page_props on the archived page omits the archived count" do
    props = presenter(archived: true).page_props

    assert_equal false, props[:has_products].call
    assert_equal true, props[:can_create_product].call
    assert_not_includes props.keys, :archived_products_count
  end

  test "#products_table_props on the archived page returns only the seller's archived products" do
    create_product(user: @seller, name: "archived_product", archived: true, price_cents: 1500)
    create_product(user: @seller, name: "normal_product")
    create_product(user: @seller, name: "deleted_archived", archived: true, deleted_at: Time.current)
    create_product(name: "other_archived", archived: true)

    names = presenter(archived: true).products_table_props[:products].map { |product| product["name"] }

    assert_includes names, "archived_product"
    assert_not_includes names, "normal_product"
    assert_not_includes names, "deleted_archived"
    assert_not_includes names, "other_archived"
  end

  test "#products_table_props on the archived page returns the full prop shape, with unarchive allowed" do
    archived_product = create_product(user: @seller, name: "archived_product", archived: true, price_cents: 1500)
    create_product(user: @seller, name: "normal_product")

    assert_props({
                   "id" => archived_product.id,
                   "name" => "archived_product",
                   "edit_url" => routes.edit_link_path(archived_product),
                   "is_duplicating" => archived_product.is_duplicating?,
                   "is_unpublished" => archived_product.draft? || archived_product.purchase_disabled_at?,
                   "permalink" => archived_product.unique_permalink,
                   "price_formatted" => archived_product.price_formatted_including_rental_verbose,
                   "revenue" => archived_product.total_usd_cents,
                   "thumbnail" => nil,
                   "display_price_cents" => archived_product.display_price_cents,
                   "url" => archived_product.long_url,
                   "url_without_protocol" => archived_product.long_url(include_protocol: false),
                   "has_duration" => archived_product.duration_in_months.present?,
                   "successful_sales_count" => archived_product.successful_sales_count,
                   "remaining_for_sale_count" => archived_product.remaining_for_sale_count,
                   "monthly_recurring_revenue" => archived_product.monthly_recurring_revenue.to_f,
                   "revenue_pending" => archived_product.revenue_pending.to_f,
                   "can_edit" => true,
                   "can_destroy" => true,
                   "can_duplicate" => true,
                   "can_archive" => false,
                   "can_unarchive" => true,
                 }, presenter(archived: true).products_table_props[:products].sole)
  end

  test "#products_table_props on the archived page filters by the search query" do
    create_product(user: @seller, name: "archived_product", archived: true)
    create_product(user: @seller, name: "another_archived", archived: true)

    names = presenter(archived: true, query: "another").products_table_props[:products].map { |product| product["name"] }

    assert_includes names, "another_archived"
    assert_not_includes names, "archived_product"
  end

  test "#products_table_props on the archived page returns nothing for a query that matches no product" do
    create_product(user: @seller, name: "archived_product", archived: true)

    assert_empty presenter(archived: true, query: "nonexistent_xyz").products_table_props[:products]
  end

  test "#memberships_table_props on the archived page returns only the seller's archived memberships" do
    create_membership_product(user: @seller, name: "archived_membership", archived: true)
    create_membership_product(user: @seller, name: "normal_membership")
    create_membership_product(user: @seller, name: "deleted_archived", archived: true, deleted_at: Time.current)
    create_membership_product(name: "other_archived", archived: true)

    names = presenter(archived: true).memberships_table_props[:memberships].map { |membership| membership["name"] }

    assert_includes names, "archived_membership"
    assert_not_includes names, "normal_membership"
    assert_not_includes names, "deleted_archived"
    assert_not_includes names, "other_archived"
  end

  test "#memberships_table_props on the archived page returns the full prop shape, with unarchive allowed" do
    archived_membership = create_membership_product(user: @seller, name: "archived_membership", archived: true)
    create_membership_product(user: @seller, name: "normal_membership")

    assert_props({
                   "id" => archived_membership.id,
                   "name" => "archived_membership",
                   "edit_url" => routes.edit_link_path(archived_membership),
                   "is_duplicating" => archived_membership.is_duplicating?,
                   "is_unpublished" => archived_membership.draft? || archived_membership.purchase_disabled_at?,
                   "permalink" => archived_membership.unique_permalink,
                   "price_formatted" => archived_membership.price_formatted_including_rental_verbose,
                   "revenue" => archived_membership.total_usd_cents,
                   "thumbnail" => nil,
                   "display_price_cents" => archived_membership.display_price_cents,
                   "url" => archived_membership.long_url,
                   "url_without_protocol" => archived_membership.long_url(include_protocol: false),
                   "has_duration" => archived_membership.duration_in_months.present?,
                   "successful_sales_count" => archived_membership.successful_sales_count,
                   "remaining_for_sale_count" => archived_membership.remaining_for_sale_count,
                   "monthly_recurring_revenue" => archived_membership.monthly_recurring_revenue.to_f,
                   "revenue_pending" => archived_membership.revenue_pending.to_f,
                   "can_edit" => true,
                   "can_destroy" => true,
                   "can_duplicate" => true,
                   "can_archive" => false,
                   "can_unarchive" => true,
                 }, presenter(archived: true).memberships_table_props[:memberships].sole)
  end

  test "#memberships_table_props on the archived page filters by the search query" do
    create_membership_product(user: @seller, name: "archived_membership", archived: true)
    create_membership_product(user: @seller, name: "another_archived", archived: true)

    names = presenter(archived: true, query: "another").memberships_table_props[:memberships].map { |membership| membership["name"] }

    assert_includes names, "another_archived"
    assert_not_includes names, "archived_membership"
  end

  test "#memberships_table_props on the archived page returns nothing for a query that matches no membership" do
    create_membership_product(user: @seller, name: "archived_membership", archived: true)

    assert_empty presenter(archived: true, query: "nonexistent_xyz").memberships_table_props[:memberships]
  end

  test "products pagination on the archived page returns one page with the page count" do
    create_list(:product, 5, user: @seller, archived: true)

    with_page_size(2) do
      props = presenter(archived: true, products_page: 1).products_table_props

      assert_equal 2, props[:products].length
      assert_equal({ page: 1, pages: 3 }, props[:products_pagination])
    end
  end

  test "products pagination on the archived page returns disjoint pages covering the archived products" do
    archived_products = create_list(:product, 5, user: @seller, archived: true)

    with_page_size(2) do
      page1 = presenter(archived: true, products_page: 1).products_table_props
      page2 = presenter(archived: true, products_page: 2).products_table_props

      assert_equal({ page: 1, pages: 3 }, page1[:products_pagination])
      assert_equal({ page: 2, pages: 3 }, page2[:products_pagination])

      page1_ids = page1[:products].map { |product| product["id"] }
      page2_ids = page2[:products].map { |product| product["id"] }
      assert_empty page1_ids & page2_ids
      assert_empty (page1_ids + page2_ids) - archived_products.map(&:id)
    end
  end

  test "memberships pagination on the archived page returns one page with the page count" do
    create_list(:membership_product, 5, user: @seller, archived: true)

    with_page_size(2) do
      props = presenter(archived: true, memberships_page: 1).memberships_table_props

      assert_equal 2, props[:memberships].length
      assert_equal({ page: 1, pages: 3 }, props[:memberships_pagination])
    end
  end

  test "memberships pagination on the archived page returns disjoint pages covering the archived memberships" do
    archived_memberships = create_list(:membership_product, 5, user: @seller, archived: true)

    with_page_size(2) do
      page1 = presenter(archived: true, memberships_page: 1).memberships_table_props
      page2 = presenter(archived: true, memberships_page: 2).memberships_table_props

      assert_equal({ page: 1, pages: 3 }, page1[:memberships_pagination])
      assert_equal({ page: 2, pages: 3 }, page2[:memberships_pagination])

      page1_ids = page1[:memberships].map { |membership| membership["id"] }
      page2_ids = page2[:memberships].map { |membership| membership["id"] }
      assert_empty page1_ids & page2_ids
      assert_empty (page1_ids + page2_ids) - archived_memberships.map(&:id)
    end
  end
end

# The dashboard caches each product's stats in a ProductCachedValue row, written
# by CacheProductDataWorker. Sidekiq runs in fake mode by default, so run the
# worker inline for this one behavior.
class DashboardProductsPagePresenterCachingTest < ActiveSupport::TestCase
  setup do
    @seller = users(:named_seller)
    # See the note in DashboardProductsPagePresenterTest#setup: the fixture
    # product would otherwise add a third cached-value row.
    links(:product).update_columns(deleted_at: Time.current)
    @pundit_user = SellerContext.new(user: users(:marketing_for_named_seller), seller: @seller)
  end

  test "reading the dashboard tables caches one row of stats per product" do
    create_product(user: @seller)
    create_membership_product(user: @seller)
    presenter = DashboardProductsPagePresenter.new(pundit_user: @pundit_user)

    assert_difference -> { ProductCachedValue.count }, 2 do
      Sidekiq::Testing.inline! do
        presenter.products_table_props
        presenter.memberships_table_props
      end
    end
  end
end

# Sorting, against real Elasticsearch.
#
# Two of the sort keys are served by Elasticsearch rather than SQL
# (Product::Sorting::ES_SORT_KEYS = display_price_cents, is_recommendable), and
# the sales-count/revenue keys sort on ProductCachedValue rows whose values are
# computed from purchase aggregations — none of which the canned responses in
# test_helper can produce. So this class installs the real client for the
# duration and imports Link + Purchase, mirroring the spec's
# :elasticsearch_wait_for_refresh tag plus the "with products and memberships"
# shared context (spec/shared_examples/with_sorting_and_pagination.rb).
class DashboardProductsPagePresenterSortingTest < ActiveSupport::TestCase
  include RealElasticsearchBridge

  setup do
    @seller = users(:named_seller)
    # See the note in DashboardProductsPagePresenterTest#setup: the fixture
    # product would otherwise appear in every ordering asserted below.
    links(:product).update_columns(deleted_at: Time.current)
    @pundit_user = SellerContext.new(user: users(:marketing_for_named_seller), seller: @seller)
    install_real_elasticsearch!([Link, Purchase])
  end

  teardown { restore_fake_elasticsearch! }

  # The shared context's fixture data, parameterized on archived the same way.
  #
  # Product prices are 1000/500/300/400 and memberships 1000/900/8-per-tier
  # (Membership 3, pay-what-you-want) / preset tiers (Membership 4); products 3
  # and 4 and memberships 3 and 4 are unpublished (purchase_disabled_at set).
  # Sales counts differ per product so the successful_sales_count and revenue
  # orderings are distinguishable.
  def create_products_and_memberships(archived: false)
    @membership1 = create_subscription_product(name: "Membership 1", archived:, user: @seller, price_cents: 1000, created_at: 4.days.ago)
    @membership2 = create_subscription_product(name: "Membership 2", archived:, user: @seller, price_cents: 900, created_at: Time.current)
    @membership3 = create_membership_product_with_preset_tiered_pwyw_pricing(name: "Membership 3", archived:, user: @seller, purchase_disabled_at: 2.days.ago, created_at: 2.days.ago)
    @membership4 = create_membership_product_with_preset_tiered_pricing(name: "Membership 4", archived:, user: @seller, purchase_disabled_at: Time.current, created_at: 3.days.ago)

    @product1 = create_product(name: "Product 1", archived:, user: @seller, price_cents: 1000, created_at: Time.current)
    @product2 = create_product(name: "Product 2", archived:, user: @seller, price_cents: 500, created_at: 4.days.ago)
    @product3 = create_product(name: "Product 3", archived:, user: @seller, price_cents: 300, purchase_disabled_at: 2.days.ago, created_at: 2.days.ago)
    @product4 = create_product(name: "Product 4", archived:, user: @seller, price_cents: 400, purchase_disabled_at: Time.current, created_at: 3.days.ago)

    # Membership 3's tiers are priced at $8 across every recurrence, so its
    # revenue and MRR sit between the two flat-priced memberships.
    @membership3.tier_category.variants.each do |tier|
      recurrence_values = BasePrice::Recurrence.all.index_with do |_recurrence_key|
        { enabled: true, price: "8", suggested_price: "8.5" }
      end
      tier.save_recurring_prices!(recurrence_values)
    end

    create_purchase(link: @membership1, is_original_subscription_purchase: true, subscription: create_subscription(link: @membership1, cancelled_at: nil), created_at: 2.days.ago)
    2.times { create_membership_purchase(link: @membership3, subscription: create_subscription(link: @membership3, cancelled_at: nil), price_cents: 800) }
    4.times { create_purchase(link: @membership2, is_original_subscription_purchase: true, subscription: create_subscription(link: @membership2, cancelled_at: nil), created_at: 2.days.ago) }

    create_list(:purchase, 2, link: @product1)
    create_list(:purchase, 3, link: @product2)
    create_list(:purchase, 4, link: @product3)
    create_list(:purchase, 6, link: @product4)

    index_model_records(Purchase)
    index_model_records(Link)
    [@membership1, @membership2, @membership3, @membership4, @product1, @product2, @product3, @product4].each do |product|
      product.product_cached_values.create!
    end
  end

  def product_names(products_sort:, page: 1, archived: false)
    DashboardProductsPagePresenter
      .new(pundit_user: @pundit_user, archived:, products_sort:, products_page: page)
      .products_table_props[:products].map { |product| product["name"] }
  end

  def membership_names(memberships_sort:, page: 1, archived: false)
    DashboardProductsPagePresenter
      .new(pundit_user: @pundit_user, archived:, memberships_sort:, memberships_page: page)
      .memberships_table_props[:memberships].map { |membership| membership["name"] }
  end

  # A page of 2 so each assertion reads the leading pair of the ordering, as the
  # spec's stub_const did.
  def with_page_size(size, &block)
    with_const_on(DashboardProductsPagePresenter, :PER_PAGE, size, &block)
  end

  # --- products --------------------------------------------------------------

  test "products sort by name in both directions" do
    create_products_and_memberships
    with_page_size(2) do
      assert_equal ["Product 1", "Product 2"], product_names(products_sort: { key: "name", direction: "asc" })
      assert_equal ["Product 4", "Product 3"], product_names(products_sort: { key: "name", direction: "desc" })
    end
  end

  test "products paginate within a sorted order" do
    create_products_and_memberships
    with_page_size(2) do
      sort = { key: "name", direction: "asc" }
      page1 = DashboardProductsPagePresenter.new(pundit_user: @pundit_user, products_sort: sort, products_page: 1).products_table_props
      page2 = DashboardProductsPagePresenter.new(pundit_user: @pundit_user, products_sort: sort, products_page: 2).products_table_props

      assert_equal ["Product 1", "Product 2"], page1[:products].map { |product| product["name"] }
      assert_equal ["Product 3", "Product 4"], page2[:products].map { |product| product["name"] }
      assert_equal({ page: 1, pages: 2 }, page1[:products_pagination])
      assert_equal({ page: 2, pages: 2 }, page2[:products_pagination])
    end
  end

  test "products sort by successful sales count in both directions" do
    create_products_and_memberships
    with_page_size(2) do
      assert_equal ["Product 1", "Product 2"], product_names(products_sort: { key: "successful_sales_count", direction: "asc" })
      assert_equal ["Product 4", "Product 3"], product_names(products_sort: { key: "successful_sales_count", direction: "desc" })
    end
  end

  test "products sort by revenue in both directions" do
    create_products_and_memberships
    with_page_size(2) do
      assert_equal ["Product 3", "Product 2"], product_names(products_sort: { key: "revenue", direction: "asc" })
      assert_equal ["Product 4", "Product 1"], product_names(products_sort: { key: "revenue", direction: "desc" })
    end
  end

  test "products sort by display price in both directions" do
    create_products_and_memberships
    with_page_size(2) do
      assert_equal ["Product 3", "Product 4"], product_names(products_sort: { key: "display_price_cents", direction: "asc" })
      assert_equal ["Product 1", "Product 2"], product_names(products_sort: { key: "display_price_cents", direction: "desc" })
    end
  end

  test "products sort by status, unpublished first ascending and published first descending" do
    create_products_and_memberships
    with_page_size(2) do
      # Status sorts on "purchase_disabled_at IS NULL", which groups rather than
      # totally orders — so the pair is asserted as a set, like the spec did.
      assert_equal ["Product 3", "Product 4"], product_names(products_sort: { key: "status", direction: "asc" }).sort
      assert_equal ["Product 1", "Product 2"], product_names(products_sort: { key: "status", direction: "desc" }).sort
    end
  end

  # --- memberships -----------------------------------------------------------

  test "memberships sort by name in both directions" do
    create_products_and_memberships
    with_page_size(2) do
      assert_equal ["Membership 1", "Membership 2"], membership_names(memberships_sort: { key: "name", direction: "asc" })
      assert_equal ["Membership 4", "Membership 3"], membership_names(memberships_sort: { key: "name", direction: "desc" })
    end
  end

  test "memberships paginate within a sorted order" do
    create_products_and_memberships
    with_page_size(2) do
      sort = { key: "name", direction: "asc" }
      page1 = DashboardProductsPagePresenter.new(pundit_user: @pundit_user, memberships_sort: sort, memberships_page: 1).memberships_table_props
      page2 = DashboardProductsPagePresenter.new(pundit_user: @pundit_user, memberships_sort: sort, memberships_page: 2).memberships_table_props

      assert_equal ["Membership 1", "Membership 2"], page1[:memberships].map { |membership| membership["name"] }
      assert_equal ["Membership 3", "Membership 4"], page2[:memberships].map { |membership| membership["name"] }
      assert_equal({ page: 1, pages: 2 }, page1[:memberships_pagination])
      assert_equal({ page: 2, pages: 2 }, page2[:memberships_pagination])
    end
  end

  test "memberships sort by successful sales count in both directions" do
    create_products_and_memberships
    with_page_size(2) do
      assert_equal ["Membership 4", "Membership 1"], membership_names(memberships_sort: { key: "successful_sales_count", direction: "asc" })
      assert_equal ["Membership 2", "Membership 3"], membership_names(memberships_sort: { key: "successful_sales_count", direction: "desc" })
    end
  end

  test "memberships sort by revenue in both directions" do
    create_products_and_memberships
    with_page_size(2) do
      assert_equal ["Membership 4", "Membership 1"], membership_names(memberships_sort: { key: "revenue", direction: "asc" })
      assert_equal ["Membership 2", "Membership 3"], membership_names(memberships_sort: { key: "revenue", direction: "desc" })
    end
  end

  test "memberships sort by display price in both directions" do
    create_products_and_memberships
    with_page_size(2) do
      assert_equal ["Membership 4", "Membership 3"], membership_names(memberships_sort: { key: "display_price_cents", direction: "asc" })
      assert_equal ["Membership 1", "Membership 2"], membership_names(memberships_sort: { key: "display_price_cents", direction: "desc" })
    end
  end

  test "memberships sort by status, unpublished first ascending and published first descending" do
    create_products_and_memberships
    with_page_size(2) do
      assert_equal ["Membership 3", "Membership 4"], membership_names(memberships_sort: { key: "status", direction: "asc" }).sort
      assert_equal ["Membership 1", "Membership 2"], membership_names(memberships_sort: { key: "status", direction: "desc" }).sort
    end
  end

  # --- archived page ---------------------------------------------------------
  #
  # The archived variants sort the whole set on one page (the spec left PER_PAGE
  # at its default here), so these assert the full four-item ordering.

  test "archived products sort by name in both directions" do
    create_products_and_memberships(archived: true)

    assert_equal ["Product 1", "Product 2", "Product 3", "Product 4"],
                 product_names(archived: true, products_sort: { key: "name", direction: "asc" })
    assert_equal ["Product 4", "Product 3", "Product 2", "Product 1"],
                 product_names(archived: true, products_sort: { key: "name", direction: "desc" })
  end

  test "archived products sort by successful sales count ascending" do
    create_products_and_memberships(archived: true)

    assert_equal ["Product 1", "Product 2", "Product 3", "Product 4"],
                 product_names(archived: true, products_sort: { key: "successful_sales_count", direction: "asc" })
  end

  test "archived products sort by revenue descending" do
    create_products_and_memberships(archived: true)

    assert_equal ["Product 4", "Product 1", "Product 2", "Product 3"],
                 product_names(archived: true, products_sort: { key: "revenue", direction: "desc" })
  end

  test "archived products sort by display price ascending" do
    create_products_and_memberships(archived: true)

    assert_equal ["Product 3", "Product 4", "Product 2", "Product 1"],
                 product_names(archived: true, products_sort: { key: "display_price_cents", direction: "asc" })
  end

  test "archived memberships sort by name in both directions" do
    create_products_and_memberships(archived: true)

    assert_equal ["Membership 1", "Membership 2", "Membership 3", "Membership 4"],
                 membership_names(archived: true, memberships_sort: { key: "name", direction: "asc" })
    assert_equal ["Membership 4", "Membership 3", "Membership 2", "Membership 1"],
                 membership_names(archived: true, memberships_sort: { key: "name", direction: "desc" })
  end

  test "archived memberships sort by successful sales count descending" do
    create_products_and_memberships(archived: true)

    assert_equal ["Membership 2", "Membership 3", "Membership 1", "Membership 4"],
                 membership_names(archived: true, memberships_sort: { key: "successful_sales_count", direction: "desc" })
  end

  test "archived memberships sort by revenue ascending" do
    create_products_and_memberships(archived: true)

    assert_equal ["Membership 4", "Membership 1", "Membership 3", "Membership 2"],
                 membership_names(archived: true, memberships_sort: { key: "revenue", direction: "asc" })
  end

  test "archived memberships sort by display price descending" do
    create_products_and_memberships(archived: true)

    assert_equal ["Membership 1", "Membership 2", "Membership 3", "Membership 4"],
                 membership_names(archived: true, memberships_sort: { key: "display_price_cents", direction: "desc" })
  end
end
