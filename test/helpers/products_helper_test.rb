# frozen_string_literal: true

require "test_helper"

# Ported from spec/helpers/products_helper_spec.rb (#5801).
#
# ActionView::TestCase gives the helper the `request` object several of these
# methods read, and mixes the helper's own methods into the test — so calls read
# the same way they do in a view.
#
# Split into two classes: the sorting method needs a real Elasticsearch cluster
# (`display_price_cents` is one of the two keys Product::Sorting routes through
# Elasticsearch rather than SQL), so it lives on its own with the bridge
# installed and leaves the rest of the tests on the fast stubbed client.
class ProductsHelperTest < ActionView::TestCase
  tests ProductsHelper

  # --- #view_content_button_text ---------------------------------------------

  test "#view_content_button_text prefers the seller's custom text" do
    product = create_product(custom_view_content_button_text: "Custom Text")

    assert_equal "Custom Text", view_content_button_text(product)
  end

  test "#view_content_button_text falls back to View content" do
    product = create_product

    assert_nil product.custom_view_content_button_text
    assert_equal "View content", view_content_button_text(product)
  end

  # --- #cdn_url_for ----------------------------------------------------------
  #
  # cdn_url_for rewrites a storage URL to its CDN equivalent by prefix. The
  # rewrite table is empty in test (config/initializers/cdn_url_map.rb only
  # populates it outside test), so each test installs one, as the spec did.

  def with_cdn_url_map(&block)
    with_const(:CDN_URL_MAP, {
                 "#{AWS_S3_ENDPOINT}/gumroad/" => "https://asset.host.example.com/res/gumroad/",
                 "#{AWS_S3_ENDPOINT}/gumroad-staging/" => "https://asset.host.example.com/res/gumroad-staging/",
                 "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/" => "https://asset.host.example.com/res/gumroad-specs/",
               }, &block)
  end

  test "#cdn_url_for rewrites a URL in the product-assets bucket to the CDN host" do
    with_cdn_url_map do
      # The URL has to be a real one from the storage service (the point is the
      # prefix match), so attach a cover and read its retina variant's key.
      # with_real_s3: the default Disk service produces a local /rails/active_storage
      # URL that no prefix in the map matches.
      with_real_s3 do
        product = create_product
        preview = create_asset_preview(link: product)
        preview.generate_retina_variant!

        assert_match "https://asset.host.example.com/res/gumroad-specs/#{preview.retina_variant.key}",
                     cdn_url_for(product.preview_url)
      ensure
        preview&.file&.purge
      end
    end
  end

  test "#cdn_url_for rewrites a URL in the staging bucket to the CDN host" do
    with_cdn_url_map do
      key = "specs/cover-#{SecureRandom.hex}.png"

      assert_equal "https://asset.host.example.com/res/gumroad-staging/#{key}",
                   cdn_url_for("#{AWS_S3_ENDPOINT}/gumroad-staging/#{key}")
    end
  end

  test "#cdn_url_for leaves a URL in an unmapped bucket alone" do
    with_cdn_url_map do
      url = "#{AWS_S3_ENDPOINT}/gumroad_other/specs/cover-#{SecureRandom.hex}.png"

      assert_equal url, cdn_url_for(url)
    end
  end

  test "#cdn_url_for returns an oembed cover's embed URL unchanged" do
    with_cdn_url_map do
      # A pasted YouTube link becomes an oembed cover, and AssetPreview#url then
      # returns the embed URL rather than a storage URL — nothing for the CDN map
      # to rewrite. OEmbedFinder talks to YouTube, so stub the lookup.
      OEmbedFinder.expects(:embeddable_from_url).returns(
        html: '<iframe src="https://madeup.url"></iframe>',
        info: { "thumbnail_url" => "https://madeup.thumbnail.url", "width" => "100", "height" => "100" }
      )
      product = create_product
      product.preview_url = "https://www.youtube.com/watch?v=ljPFZrRD3J8"
      product.save!

      assert_equal "https://madeup.url", cdn_url_for(product.preview_url)
    end
  end

  test "#cdn_url_for passes an empty URL through" do
    with_cdn_url_map do
      assert_equal "", cdn_url_for("")
    end
  end

  # --- #url_for_product_page -------------------------------------------------
  #
  # Two shapes, matching the spec's two shared example groups:
  #
  #   * "long url" — the product's absolute gumroad.com URL, used whenever the
  #     request is not on the seller's own storefront.
  #   * "relative url" — a /l/<permalink> path on the request's own host, used
  #     when the request IS on the seller's storefront (subdomain or custom
  #     domain), so the buyer stays on that domain.

  def assert_long_url(product)
    assert_equal product.long_url(recommended_by: "test"),
                 url_for_product_page(product, request:, recommended_by: "test")
  end

  def assert_long_url_with_offer_code(product)
    assert_equal product.long_url(recommended_by: "test", code: "BLACKFRIDAY2025"),
                 url_for_product_page(product, request:, recommended_by: "test", offer_code: "BLACKFRIDAY2025")
  end

  def assert_relative_url(product)
    assert_equal "http://#{request.host_with_port}/l/#{product.general_permalink}?recommended_by=test",
                 url_for_product_page(product, request:, recommended_by: "test")
    assert_equal "http://#{request.host_with_port}/l/#{product.general_permalink}",
                 url_for_product_page(product, request:, recommended_by: "")
  end

  test "#url_for_product_page returns the long URL when there is no request" do
    product = create_product

    assert_equal product.long_url(recommended_by: "test"),
                 url_for_product_page(product, request: nil, recommended_by: "test")
    assert_equal product.long_url(recommended_by: "test", code: "BLACKFRIDAY2025"),
                 url_for_product_page(product, request: nil, recommended_by: "test", offer_code: "BLACKFRIDAY2025")
  end

  test "#url_for_product_page returns the long URL on the main Gumroad domain" do
    product = create_product
    with_const(:DOMAIN, "127.0.0.1") do
      request.host = DOMAIN

      assert_long_url(product)
      assert_long_url_with_offer_code(product)
    end
  end

  test "#url_for_product_page returns the long URL on the Discover host" do
    product = create_product
    request.host = VALID_DISCOVER_REQUEST_HOST

    assert_long_url(product)
    assert_long_url_with_offer_code(product)
  end

  test "#url_for_product_page returns a same-host path on the seller's subdomain" do
    product = create_product
    request.host = product.user.subdomain

    assert_relative_url(product)
  end

  test "#url_for_product_page returns a same-host path on the seller's custom domain" do
    product = create_product
    create_custom_domain(user: product.user, domain: "example.com")
    request.host = "example.com"

    assert_relative_url(product)
  end

  test "#url_for_product_page returns the long URL on another seller's subdomain" do
    product = create_product
    request.host = create_user.subdomain

    assert_long_url(product)
    assert_long_url_with_offer_code(product)
  end

  test "#url_for_product_page returns the long URL on another seller's custom domain" do
    product = create_product
    create_custom_domain(user: create_user, domain: "example.com")
    request.host = "example.com"

    assert_long_url(product)
    assert_long_url_with_offer_code(product)
  end

  # --- #variant_names_displayable --------------------------------------------

  test "#variant_names_displayable is nil when there are no names" do
    assert_nil variant_names_displayable([])
  end

  test "#variant_names_displayable is nil for the placeholder Untitled variant" do
    # A single-variant product's one variant is named "Untitled", which is an
    # implementation detail buyers should never see.
    assert_nil variant_names_displayable(["Untitled"])
  end

  test "#variant_names_displayable joins real names" do
    assert_equal "name1, name2", variant_names_displayable(%w[name1 name2])
  end

  # --- #files_data -----------------------------------------------------------

  test "#files_data eager-loads subtitles, transcoded videos, and thumbnails instead of querying per file" do
    product = create_product
    file_one = create_streamable_video(link: product, position: 0)
    file_two = create_streamable_video(link: product, position: 1)
    create_subtitle_file(product_file: file_one)
    create_subtitle_file(product_file: file_two)
    create_transcoded_video(streamable: file_one, original_video_key: file_one.s3_key, state: "completed")
    create_transcoded_video(streamable: file_two, original_video_key: file_two.s3_key, state: "completed")

    # Pre-warm: hit the path once to fault in any one-time caches.
    files_data(product)

    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      next if payload[:name] == "SCHEMA"
      next if payload[:cached]
      queries << payload[:sql] if payload[:sql].start_with?("SELECT")
    end

    begin
      # Reload to force a fresh association cache, so the eager-load is what
      # keeps the query count flat rather than a stale memoised result.
      product.reload
      files_data(product)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    # A per-row query names one id in its WHERE clause; the eager-loaded version
    # uses IN (...) for all of them. Assert on the shape rather than a total
    # count, so an unrelated extra query elsewhere doesn't fail this test.
    {
      /FROM `subtitle_files`.*WHERE.*`product_file_id` = \d+/ => "subtitle_files",
      /FROM `transcoded_videos`.*WHERE.*`streamable_id` = \d+/ => "transcoded_videos",
      /FROM `active_storage_attachments`.*WHERE.*`record_id` = \d+ AND.*`record_type` = 'ProductFile' AND.*`name` = 'thumbnail'/ => "thumbnail attachment",
    }.each do |pattern, label|
      hits = queries.grep(pattern)
      assert_empty hits, "Expected no per-row #{label} queries, got #{hits.size}:\n#{hits.join("\n")}"
    end
  end
end

# #sort_and_paginate_products, against real Elasticsearch.
#
# The method routes the sort key either to SQL or to Elasticsearch depending on
# Product::Sorting::ES_SORT_KEYS, and this test covers one of each ("name" is
# SQL, "display_price_cents" is Elasticsearch) — so the stubbed client, which
# returns an empty result set for every search, can't serve it.
class ProductsHelperSortAndPaginateTest < ActionView::TestCase
  tests ProductsHelper
  include RealElasticsearchBridge

  setup do
    # Purchase is in the list even though nothing here queries it directly:
    # indexing a Link computes total_usd_cents (Product::Searchable
    # #build_search_property), which searches the purchases index. Without
    # Purchase namespaced, that read goes to an unnamespaced `purchases` index —
    # absent on CI (404 on index_model_records) and, locally, your actual
    # development index. This is the "pass every model whose index the test can
    # touch" rule in RealElasticsearchBridge.
    install_real_elasticsearch!([Link, Purchase])

    @seller = create_recommendable_user
    # Prices ascend p1 < p3 < p2 < p4 so the price ordering differs from the
    # name ordering; two of the four are memberships, which the dashboard sorts
    # in the same collection here.
    @product1 = create_product(user: @seller, name: "p1", price_cents: 100, display_product_reviews: true, taxonomy: create_taxonomy, purchase_disabled_at: Time.current)
    @product2 = create_product(user: @seller, name: "p2", price_cents: 300, display_product_reviews: false, taxonomy: create_taxonomy)
    @product3 = create_subscription_product(user: @seller, name: "p3", price_cents: 200, display_product_reviews: false, purchase_disabled_at: Time.current)
    @product4 = create_subscription_product(user: @seller, name: "p4", price_cents: 600, display_product_reviews: true)

    index_model_records(Link)
  end

  teardown { restore_fake_elasticsearch! }

  def page_of(key:, page:)
    sort_and_paginate_products(key:, direction: "asc", page:, collection: @seller.products, per_page: 2, user_id: @seller.id)
  end

  test "#sort_and_paginate_products paginates a SQL-sorted key" do
    pagination, products = page_of(key: "name", page: 1)
    assert_equal({ page: 1, pages: 2 }, pagination)
    assert_equal [@product1, @product2], products.to_a

    pagination, products = page_of(key: "name", page: 2)
    assert_equal({ page: 2, pages: 2 }, pagination)
    assert_equal [@product3, @product4], products.to_a
  end

  test "#sort_and_paginate_products paginates an Elasticsearch-sorted key" do
    # Compared by name rather than by record: the Elasticsearch branch returns
    # `response.records`, whose objects are loaded separately from the ones built
    # above.
    pagination, products = page_of(key: "display_price_cents", page: 1)
    assert_equal({ page: 1, pages: 2 }, pagination)
    assert_equal [@product1.name, @product3.name], products.map(&:name)

    pagination, products = page_of(key: "display_price_cents", page: 2)
    assert_equal({ page: 2, pages: 2 }, pagination)
    assert_equal [@product2.name, @product4.name], products.map(&:name)
  end
end
