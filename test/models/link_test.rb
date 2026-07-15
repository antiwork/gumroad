# frozen_string_literal: true

require "test_helper"

# Ported from spec/models/link_spec.rb. Link (a product) is exercised mostly
# through model logic — validations, callbacks, pricing, scopes — so objects
# are built with the shared ModelFactories helpers (create_product/build_product,
# create_variant, …). The RSpec file was tagged :vcr defensively, but the
# product model paths here make no external HTTP calls.
class LinkTest < ActiveSupport::TestCase
  setup do
    @product = create_product
  end

  # --- #custom_html= ---------------------------------------------------------

  test "custom_html= clears the page HTML without marking the associated page for destruction" do
    @product.update!(custom_html: "<section>Live landing page</section>")
    page = @product.reload.page

    @product.custom_html = nil

    assert_equal page, @product.page
    refute @product.page.marked_for_destruction?

    @product.save!

    assert_equal page, @product.reload.page
    assert_nil @product.custom_html
  end

  test "is not a single-unit currency" do
    assert_equal false, @product.send(:single_unit_currency?)
  end

  # --- max_purchase_count validation -----------------------------------------

  test "max_purchase_count can be set on new records with no purchases" do
    assert build_product(max_purchase_count: nil).valid?
    assert build_product(max_purchase_count: 100).valid?
  end

  test "max_purchase_count prevents changing below inventory sold" do
    product = create_product(max_purchase_count: 5)
    2.times { create_purchase(link: product) }
    product.reload
    assert product.valid?
    product.max_purchase_count = 1
    assert_equal false, product.valid?
  end

  test "max_purchase_count does not invalidate the record when inventory sold already exceeds it" do
    product = create_product
    2.times { create_purchase(link: product) }
    product.update_column(:max_purchase_count, 1)
    assert product.reload.valid?
  end

  test "max_purchase_count treats a nil sales_count_for_inventory as zero" do
    product = create_product(max_purchase_count: 100)
    product.stub(:sales_count_for_inventory, nil) do
      product.max_purchase_count = 50
      assert_nothing_raised { product.valid? }
      assert product.valid?
    end
  end

  # --- price_must_be_within_range validation ---------------------------------

  test "allows products over $1000 for verified users" do
    assert build_product(user: create_user(verified: true), price_cents: 100_100).valid?
  end

  test "price is valid within acceptable bounds" do
    assert build_product(price_cents: 1_00).valid?
    assert build_product(price_cents: 5000_00).valid?
  end

  test "price fails when too high" do
    product = build_product(price_cents: 5000_01)
    refute product.valid?
    assert_includes product.errors.full_messages, "Sorry, we don't support pricing products above $5,000."
  end

  test "price fails when it exceeds the maximum storable value" do
    error = assert_raises(Link::LinkInvalid) do
      build_product(user: create_user(verified: true), price_cents: 2_147_483_648)
    end
    assert_equal "Sorry, the price entered is too large.", error.message
  end

  test "price fails when too low" do
    product = build_product(price_cents: 98)
    refute product.valid?
    assert_includes product.errors.full_messages, "Sorry, a product must be at least $0.99."
  end

  test "price validates against the current currency when switching currencies" do
    product = create_product(price_currency_type: "usd", price_cents: 100)
    usd_price = product.default_price
    assert_equal "usd", usd_price.currency
    assert_equal 100, usd_price.price_cents

    error = assert_raises(ActiveRecord::RecordInvalid) do
      product.update!(price_currency_type: "inr", price_cents: 5000)
    end
    assert_equal "Validation failed: Sorry, a product must be at least ₹73.", error.message

    # USD 1.00 is below the INR 73.00 threshold but is ignored — it's not the current currency.
    assert_nothing_raised { product.update!(price_currency_type: "inr", price_cents: 50000) }
  end

  test "price adds an error for an unsupported currency type" do
    product = build_product(price_currency_type: "xyz", price_cents: 100)
    refute product.valid?
    assert_includes product.errors.full_messages, "'xyz' is not a supported currency."
  end

  # --- native_type inclusion validation --------------------------------------

  test "native_type fails when nil" do
    product = build_product(native_type: nil)
    assert product.invalid?
    assert_raises(ActiveRecord::NotNullViolation) { product.save!(validate: false) }
  end

  test "native_type succeeds when in the allowed list" do
    assert build_product(native_type: "digital").valid?
  end

  test "native_type fails when not in the allowed list" do
    product = build_product(native_type: "invalid")
    refute product.valid?
    assert_includes product.errors.full_messages, "Product type is not included in the list"
  end

  # --- discover_fee_per_thousand inclusion validation ------------------------

  test "discover_fee_per_thousand succeeds when in the allowed list" do
    product = build_product
    [100, 300, 1000, 400, 100].each do |fee|
      product.discover_fee_per_thousand = fee
      assert product.valid?, "expected #{fee} to be valid"
    end
  end

  test "discover_fee_per_thousand fails when not in the allowed list" do
    product = build_product
    message = "Gumroad fee must be between 30% and 100%"
    [0, nil, -1, 10, 1001].each do |fee|
      product.discover_fee_per_thousand = fee
      refute product.valid?, "expected #{fee.inspect} to be invalid"
      assert_includes product.errors.full_messages, message
    end
  end
end
