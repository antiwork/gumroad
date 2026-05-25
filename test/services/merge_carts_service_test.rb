# frozen_string_literal: true

require "test_helper"

class MergeCartsServiceTest < ActiveSupport::TestCase
  setup do
    @user = users(:named_seller)
    @browser_guid = SecureRandom.uuid
    # Remove any pre-existing alive cart from fixtures so create! doesn't trip
    # the "alive cart already exists" uniqueness validation.
    Cart.where(user: @user).delete_all
  end

  test "updates target cart details when source cart is nil" do
    cart = Cart.create!(user: @user, browser_guid: "old-browser-guid")

    MergeCartsService.new(source_cart: nil, target_cart: cart, user: @user, browser_guid: @browser_guid).process

    cart.reload
    assert_equal @browser_guid, cart.browser_guid
    assert_equal @user.email, cart.email
    assert_equal @user.id, cart.user_id
    assert_nil cart.deleted_at
    assert_equal 1, Cart.alive.count
  end

  test "updates source cart details when target cart is nil" do
    cart = Cart.create!(user: nil, browser_guid: @browser_guid)

    MergeCartsService.new(source_cart: cart, target_cart: nil, user: @user, browser_guid: @browser_guid).process

    cart.reload
    assert_equal @user.id, cart.user_id
    assert_equal @browser_guid, cart.browser_guid
    assert_equal @user.email, cart.email
    assert_equal cart.id, Cart.alive.sole.id
  end

  test "does nothing if the source cart is the same as the target cart" do
    cart = Cart.create!(user: @user, browser_guid: @browser_guid)
    before = cart.attributes

    assert_no_difference "Cart.alive.count" do
      MergeCartsService.new(source_cart: cart, target_cart: cart, user: @user, browser_guid: @browser_guid).process
    end

    assert_equal before, cart.reload.attributes
  end

  test "deletes the source cart when both have no alive cart products" do
    source_cart = Cart.create!(user: nil, browser_guid: SecureRandom.uuid, email: "source@example.com")
    target_cart = Cart.create!(user: nil, browser_guid: @browser_guid)

    assert_difference "Cart.alive.count", -1 do
      MergeCartsService.new(source_cart: source_cart, target_cart: target_cart, browser_guid: @browser_guid).process
    end

    assert_equal target_cart.id, Cart.alive.sole.id
    assert_equal "source@example.com", target_cart.reload.email
  end

  test "merges cart products, discount codes, and other attributes from source to target" do
    product1 = links(:named_seller_product)
    product2 = links(:upsell_test_product)
    variant_category = VariantCategory.create!(link: product2, title: "Size")
    product2_variant = Variant.create!(variant_category: variant_category, name: "Large")
    product3 = links(:another_seller_product)

    source_cart = Cart.create!(
      user: nil,
      browser_guid: SecureRandom.uuid,
      return_url: "https://example.com/source",
      discount_codes: [{ "code" => "ABC123", "fromUrl" => false }, { "code" => "XYZ789", "fromUrl" => false }],
      reject_ppp_discount: true,
    )
    target_cart = Cart.create!(
      user: nil,
      browser_guid: @browser_guid,
      discount_codes: [{ "code" => "DEF456", "fromUrl" => false }, { "code" => "ABC123", "fromUrl" => false }],
    )

    CartProduct.create!(cart: source_cart, product: product1, price: product1.price_cents, quantity: 1, referrer: "direct")
    CartProduct.create!(cart: source_cart, product: product2, option: product2_variant, price: product2.price_cents, quantity: 1, referrer: "direct")
    CartProduct.create!(cart: target_cart, product: product3, price: product3.price_cents, quantity: 1, referrer: "direct")

    assert_difference -> { Cart.alive.count } => -1,
                      -> { target_cart.reload.cart_products.count } => 2 do
      MergeCartsService.new(source_cart: source_cart, target_cart: target_cart, browser_guid: @browser_guid).process
    end

    assert_equal target_cart.id, Cart.alive.sole.id
    assert_equal "https://example.com/source", target_cart.return_url
    assert_equal ["DEF456", "ABC123", "XYZ789"], target_cart.discount_codes.map { _1["code"] }
    assert_equal true, target_cart.reject_ppp_discount
    assert_equal(
      [[product1.id, nil], [product2.id, product2_variant.id], [product3.id, nil]].sort,
      target_cart.alive_cart_products.pluck(:product_id, :option_id).sort,
    )
    assert_equal @browser_guid, target_cart.browser_guid
    assert_nil target_cart.email
  end
end
