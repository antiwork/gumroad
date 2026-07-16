# frozen_string_literal: true

require "test_helper"

# Guards the core fixture cascade (user -> product -> price -> merchant account
# -> purchase) that every ranked migration file builds on. If a schema or
# validation change breaks one of these rows, this fails loudly here instead of
# in whichever file happens to reference it next.
class CoreFixturesTest < ActiveSupport::TestCase
  test "core rows load and pass validations" do
    [
      users(:named_seller),
      users(:buyer),
      merchant_accounts(:gumroad_stripe),
      links(:product),
      prices(:product_price),
      purchases(:successful_purchase),
    ].each do |record|
      assert record.valid?, "#{record.class}(#{record.id}) invalid: #{record.errors.full_messages.join(", ")}"
    end
  end

  test "product reads its price from the associated Price row" do
    product = links(:product)
    assert_equal 100, product.price_cents
    assert_equal 100, product.default_price_cents
    assert_equal users(:named_seller), product.user
  end

  test "gumroad_stripe is the platform-managed account MerchantAccount.gumroad resolves" do
    account = merchant_accounts(:gumroad_stripe)
    assert_nil account.user_id
    assert account.is_managed_by_gumroad?
    assert_equal account, MerchantAccount.gumroad("stripe")
  end

  test "successful_purchase wires seller, buyer, product and platform account" do
    purchase = purchases(:successful_purchase)
    assert_equal users(:named_seller), purchase.seller
    assert_equal users(:buyer), purchase.purchaser
    assert_equal links(:product), purchase.link
    assert_equal purchase.link.user, purchase.seller
    assert_equal merchant_accounts(:gumroad_stripe), purchase.merchant_account
    assert purchase.successful?
    assert_equal 93, purchase.fee_cents
  end
end
