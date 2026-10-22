# frozen_string_literal: true

require "test_helper"

# gp#3730 option A: physical goods sell only to the US, Canada, and the UK, where we collect the
# tax on them. Gated by Product::Shipping::SUPPORTED_COUNTRIES_FEATURE so it can ship dark.
class ProductShippingSupportedCountriesTest < ActiveSupport::TestCase
  setup do
    @product = create_product(price_cents: 10_00, is_physical: true, require_shipping: true)
    @product.shipping_destinations << ShippingDestination.new(country_code: Product::Shipping::ELSEWHERE, one_item_rate_cents: 5_00, multiple_items_rate_cents: 2_00)
    @product.save!
  end

  teardown { Feature.deactivate(Product::Shipping::SUPPORTED_COUNTRIES_FEATURE) }

  test "with the flag off, a catch-all destination still ships everywhere" do
    assert_includes @product.shippable_country_codes, "DE"
    assert ShippingDestination.for_product_and_country_code(product: @product, country_code: "DE")
    assert Product::Shipping.supported_country?("DE")
  end

  test "with the flag on, checkout only offers the US, Canada, and the UK" do
    Feature.activate(Product::Shipping::SUPPORTED_COUNTRIES_FEATURE)

    assert_equal %w[CA GB US], @product.reload.shippable_country_codes.sort
    assert_not Product::Shipping.supported_country?("DE")
    assert Product::Shipping.supported_country?("gb")
  end

  test "with the flag on, a new sale shipping to Germany is refused" do
    Feature.activate(Product::Shipping::SUPPORTED_COUNTRIES_FEATURE)
    purchase = build_purchase(link: @product, country: "Germany", price_cents: 15_00, quantity: 1)

    purchase.send(:validate_shipping)

    assert_equal PurchaseErrorCode::NO_SHIPPING_COUNTRY_CONFIGURED, purchase.error_code
    assert_match "United States, Canada, and the United Kingdom", purchase.errors[:base].first
  end

  test "with the flag on, a new sale shipping to the UK goes through" do
    Feature.activate(Product::Shipping::SUPPORTED_COUNTRIES_FEATURE)
    purchase = build_purchase(link: @product, country: "United Kingdom", price_cents: 15_00, quantity: 1)

    purchase.send(:validate_shipping)

    assert_nil purchase.error_code
    assert_empty purchase.errors[:base]
  end

  test "with the flag on, a recurring charge on an existing subscription keeps shipping where it was sold" do
    Feature.activate(Product::Shipping::SUPPORTED_COUNTRIES_FEATURE)
    purchase = build_purchase(link: @product, country: "Germany", price_cents: 15_00, quantity: 1)
    purchase.define_singleton_method(:is_recurring_subscription_charge) { true }

    purchase.send(:validate_shipping)

    assert_nil purchase.error_code
  end

  test "with the flag on, the manage page keeps the country a subscription was sold to" do
    Feature.activate(Product::Shipping::SUPPORTED_COUNTRIES_FEATURE)
    product = create_subscription_product(price_cents: 10_00, is_physical: true, require_shipping: true)
    product.shipping_destinations << ShippingDestination.new(country_code: "DE", one_item_rate_cents: 5_00, multiple_items_rate_cents: 2_00)
    product.save!
    subscription = create_subscription(link: product)
    create_membership_purchase(link: product, subscription:, country: "Germany", full_name: "Jane Doe",
                               street_address: "1 Test St", city: "Berlin", state: "Berlin", zip_code: "10115")

    props = CheckoutPresenter.new(logged_in_user: nil, ip: nil)
                             .subscription_manager_props(subscription: subscription.reload)[:product]

    assert_equal [], product.reload.shippable_country_codes
    assert_equal ["DE"], props[:shippable_country_codes]
    assert_equal false, props[:ships_nowhere]
  end

  test "with the flag on, publishing a product that only ships outside the supported countries explains why" do
    Feature.activate(Product::Shipping::SUPPORTED_COUNTRIES_FEATURE)
    product = create_product(price_cents: 10_00, is_physical: true, require_shipping: true, purchase_disabled_at: Time.current)
    product.shipping_destinations << ShippingDestination.new(country_code: "DE", one_item_rate_cents: 5_00, multiple_items_rate_cents: 2_00)
    product.save!

    error = assert_raises(Link::LinkInvalid) { product.send(:enforce_shipping_destinations_presence!) }
    assert_match "United States, Canada, and the United Kingdom", error.message
  end
end
