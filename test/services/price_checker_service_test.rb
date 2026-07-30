# frozen_string_literal: true

require "test_helper"

# Ported from spec/services/price_checker_service_spec.rb (#5801).
class PriceCheckerServiceTest < ActiveSupport::TestCase
  include RealElasticsearchBridge

  setup do
    install_real_elasticsearch!([Link, Purchase])
    Rails.cache.clear
    Link.any_instance.stubs(:recommendable?).returns(true)

    @films_taxonomy = Taxonomy.find_or_create_by!(slug: "films")
    @design_taxonomy = Taxonomy.find_or_create_by!(slug: "design")
    @seller = users(:named_seller)
    @matching_seller = users(:basic_user)
    @product = links(:product)
    # Keep future Link fixtures out of the real Elasticsearch index so they
    # cannot silently change match counts in these distribution assertions.
    Link.where.not(id: @product.id).update_all(deleted_at: Time.current)
    @product.update!(
      name: "My film masterpiece",
      description: "A documentary about widgets in the wild.",
      price_cents: 1_500,
      taxonomy: @films_taxonomy,
    )
  end

  teardown do
    Rails.cache.clear
    restore_fake_elasticsearch!
  end

  test "returns the same-taxonomy distribution when at least five products match" do
    create_matching_products(
      count: 12,
      taxonomy: @films_taxonomy,
      name: ->(index) { "Film number #{index}" },
      description: "A documentary similar to widgets.",
      price_cents: ->(index) { 500 + index * 250 },
    )
    index_products

    result = PriceCheckerService.call(product: @product)

    assert_equal "ok", result[:status]
    assert_equal "with_taxonomy", result[:tier]
    assert_operator result[:match_count], :>=, 5
    assert_equal "usd", result[:currency_code]
    assert_equal 1_500, result[:current_price_cents]
    assert_operator result[:summary][:median_cents], :>, 0
    assert_operator result[:summary][:p25_cents], :<=, result[:summary][:median_cents]
    assert_operator result[:summary][:p75_cents], :>=, result[:summary][:median_cents]
    assert_not_empty result[:histogram][:bins]
    assert_operator result[:histogram][:interval_cents], :>, 0
  end

  test "broadens beyond taxonomy when fewer than five same-taxonomy products match" do
    create_matching_products(
      count: 2,
      taxonomy: @films_taxonomy,
      name: ->(index) { "Film #{index}" },
      price_cents: ->(index) { 1_000 + index * 500 },
    )
    create_matching_products(
      count: 12,
      taxonomy: @design_taxonomy,
      name: ->(index) { "Documentary widgets #{index}" },
      description: "A documentary about widgets.",
      price_cents: ->(index) { 300 + index * 200 },
    )
    index_products

    result = PriceCheckerService.call(product: @product)

    assert_equal "ok", result[:status]
    assert_equal "broadened", result[:tier]
    assert_operator result[:match_count], :>=, 5
    assert_nil result[:taxonomy_label]
  end

  test "returns insufficient data when fewer than five products match after broadening" do
    create_matching_products(
      count: 2,
      taxonomy: @films_taxonomy,
      price_cents: ->(index) { 999 + index },
    )
    index_products

    result = PriceCheckerService.call(product: @product)

    assert_equal "insufficient_data", result[:status]
    assert_equal "insufficient", result[:tier]
    assert_nil result[:summary]
    assert_nil result[:histogram]
    assert_equal 1_500, result[:current_price_cents]
  end

  test "uses taxonomy name and description overrides for matching" do
    create_matching_products(
      count: 12,
      taxonomy: @design_taxonomy,
      name: ->(index) { "Design template kit #{index}" },
      description: "A design template for designers.",
      price_cents: ->(index) { 4_000 + index * 200 },
    )
    index_products

    result = PriceCheckerService.call(
      product: @product,
      overrides: {
        taxonomy_id: @design_taxonomy.id,
        name: "Design template kit",
        description: "A design template for designers.",
      },
    )

    assert_equal "ok", result[:status]
    assert_equal "with_taxonomy", result[:tier]
    assert_includes 4_000..6_400, result[:summary][:median_cents]
  end

  test "returns insufficient data when the relevance filter excludes unrelated products" do
    create_matching_products(
      count: 12,
      taxonomy: @films_taxonomy,
      name: ->(index) { "Quantum widget #{index}" },
      description: "Crystal latte tutorial.",
      price_cents: ->(index) { 500 + index * 100 },
    )
    index_products

    result = PriceCheckerService.call(product: @product)

    assert_equal "insufficient_data", result[:status]
    assert_equal "insufficient", result[:tier]
  end

  test "returns insufficient data when Elasticsearch returns null percentiles" do
    null_percentiles = { "5.0" => nil, "25.0" => nil, "50.0" => nil, "75.0" => nil, "95.0" => nil }
    response = stub(
      results: stub(total: 12),
      aggregations: stub(dig: null_percentiles),
      response: { "timed_out" => false },
    )
    Link.stubs(:search).returns(response)

    result = PriceCheckerService.call(product: @product)

    assert_equal "insufficient_data", result[:status]
    assert_nil result[:summary]
  end

  test "excludes products with a different seller bundle pricing currency or native type" do
    matching_attributes = {
      name: "Film masterpiece",
      description: "A documentary about widgets in the wild.",
      taxonomy: @films_taxonomy,
    }

    create_product(user: @seller, price_cents: 5_000, **matching_attributes)
    create_subscription_product(user: @matching_seller, price_cents: 700, **matching_attributes)
    create_bundle(user: @matching_seller, price_cents: 800, taxonomy: @films_taxonomy)
    create_product(user: @matching_seller, customizable_price: true, price_cents: 900, **matching_attributes)
    create_product(user: @matching_seller, price_currency_type: "eur", price_cents: 1_100, **matching_attributes)
    create_physical_product(user: @matching_seller, price_cents: 1_200, **matching_attributes)
    create_matching_products(
      count: 12,
      taxonomy: @films_taxonomy,
      name: ->(index) { "Film masterpiece #{index}" },
      description: "A documentary about widgets in the wild.",
      price_cents: ->(index) { 600 + index * 100 },
    )
    index_products

    result = PriceCheckerService.call(product: @product)

    assert_equal "ok", result[:status]
    assert_equal 12, result[:match_count]
  end

  test "caches results and bypasses the cache when force refresh is true" do
    create_matching_products(
      count: 12,
      taxonomy: @films_taxonomy,
      name: ->(index) { "Film masterpiece #{index}" },
      description: "A documentary about widgets in the wild.",
      price_cents: ->(index) { 500 + index * 100 },
    )
    index_products

    # Assert per-call deltas, not a total: one uncached call already makes two
    # searches (percentiles + histogram), so any total-count floor passes even
    # with caching or force_refresh broken.
    capture_search_calls do |search_calls|
      PriceCheckerService.call(product: @product)
      uncached_searches = search_calls.call
      assert_operator uncached_searches, :>, 0

      PriceCheckerService.call(product: @product)
      assert_equal uncached_searches, search_calls.call

      PriceCheckerService.call(product: @product, force_refresh: true)
      assert_operator search_calls.call, :>, uncached_searches
    end
  end

  test "stores the result under a stable cache key" do
    create_matching_products(
      count: 12,
      taxonomy: @films_taxonomy,
      name: ->(index) { "Film masterpiece #{index}" },
      description: "A documentary about widgets in the wild.",
      price_cents: ->(index) { 500 + index * 100 },
    )
    index_products

    result = PriceCheckerService.call(product: @product)
    fingerprint = Digest::MD5.hexdigest(
      [
        @product.name,
        Digest::MD5.hexdigest(@product.description.to_s.first(1_000)),
        @product.native_type,
        @product.is_recurring_billing,
        @product.price_currency_type,
        @product.taxonomy_id,
      ].join("|")
    )

    assert_equal result, Rails.cache.read("price_checker:v3:#{@product.id}:#{fingerprint}")
  end

  test "uses different cache keys for different descriptions" do
    first = PriceCheckerService.new(product: @product, overrides: { description: "First description content" })
    second = PriceCheckerService.new(product: @product, overrides: { description: "Completely different second description content" })

    assert_not_equal first.send(:cache_key), second.send(:cache_key)
  end

  test "uses different cache keys for different currencies" do
    usd = PriceCheckerService.new(product: @product, overrides: { currency_code: "usd" })
    eur = PriceCheckerService.new(product: @product, overrides: { currency_code: "eur" })

    assert_not_equal usd.send(:cache_key), eur.send(:cache_key)
  end

  test "returns the effective currency override" do
    result = PriceCheckerService.call(product: @product, overrides: { currency_code: "eur" })

    assert_equal "eur", result[:currency_code]
  end

  test "omits the taxonomy label for the other taxonomy" do
    other_taxonomy = Taxonomy.find_or_create_by!(slug: "other")
    @product.update!(taxonomy: other_taxonomy)
    create_matching_products(
      count: 12,
      taxonomy: other_taxonomy,
      name: ->(index) { "Film masterpiece #{index}" },
      description: "A documentary about widgets in the wild.",
      price_cents: ->(index) { 500 + index * 100 },
    )
    index_products

    result = PriceCheckerService.call(product: @product)

    assert_equal "ok", result[:status]
    assert_equal "with_taxonomy", result[:tier]
    assert_nil result[:taxonomy_label]
  end

  test "raises its timeout error when Elasticsearch reports a timeout" do
    response = stub(
      results: stub(total: 12),
      aggregations: stub(dig: {}),
      response: { "timed_out" => true },
    )
    Link.stubs(:search).returns(response)

    assert_raises(PriceCheckerService::TimeoutError) do
      PriceCheckerService.call(product: @product)
    end
  end

  test "raises its timeout error when the Ruby timeout expires" do
    Link.stubs(:search).with do
      sleep 5
      true
    end

    assert_raises(PriceCheckerService::TimeoutError) do
      PriceCheckerService.call(product: @product)
    end
  end

  private
    def create_matching_products(count:, taxonomy:, name: nil, description: nil, price_cents:)
      count.times do |index|
        attributes = {
          user: @matching_seller,
          taxonomy:,
          price_cents: callable_value(price_cents, index),
        }
        attributes[:name] = callable_value(name, index) unless name.nil?
        attributes[:description] = callable_value(description, index) unless description.nil?
        create_product(**attributes)
      end
    end

    def callable_value(value, index)
      value.respond_to?(:call) ? value.call(index) : value
    end

    def index_products
      index_model_records(Link)
    end

    def capture_search_calls
      calls = 0
      singleton_class = Link.singleton_class
      had_own_search = singleton_class.instance_methods(false).include?(:search)
      original_unbound_search = singleton_class.instance_method(:search) if had_own_search
      original_search = Link.method(:search)
      singleton_class.define_method(:search) do |*args, **kwargs, &block|
        calls += 1
        original_search.call(*args, **kwargs, &block)
      end
      yield -> { calls }
    ensure
      if had_own_search
        singleton_class.define_method(:search, original_unbound_search)
      else
        singleton_class.remove_method(:search)
      end
    end
end
