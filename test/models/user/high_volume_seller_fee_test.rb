# frozen_string_literal: true

require "test_helper"

class User::HighVolumeSellerFeeTest < ActiveSupport::TestCase
  setup do
    @seller = create_user
    Feature.activate(:high_volume_seller_fee)
  end

  teardown do
    Feature.deactivate(:high_volume_seller_fee)
  end

  test "gumroad_fee_per_thousand is 10% when the seller is not volume-eligible" do
    assert_equal Purchase::GUMROAD_FLAT_FEE_PER_THOUSAND, @seller.gumroad_fee_per_thousand
    assert_not @seller.high_volume_seller_fee?
  end

  test "gumroad_fee_per_thousand is 5% when the flag is on and the seller is volume-eligible" do
    mark_volume_eligible!(@seller)

    assert @seller.high_volume_seller_fee?
    assert_equal User::HIGH_VOLUME_FEE_PER_THOUSAND, @seller.gumroad_fee_per_thousand
  end

  test "gumroad_fee_per_thousand stays 10% when the seller is eligible but the flag is off" do
    Feature.deactivate(:high_volume_seller_fee)
    mark_volume_eligible!(@seller)

    assert_not @seller.high_volume_seller_fee?
    assert_equal Purchase::GUMROAD_FLAT_FEE_PER_THOUSAND, @seller.gumroad_fee_per_thousand
  end

  test "a negotiated custom fee wins over the volume rate" do
    mark_volume_eligible!(@seller)
    @seller.update!(custom_fee_per_thousand: 40)

    assert_equal 40, @seller.gumroad_fee_per_thousand
  end

  test "trailing_month_gross_sales_cents sums paid sales inside the window and ignores older or refunded ones" do
    product = create_product(user: @seller)
    create_purchase(link: product, seller: @seller, price_cents: 1_500_000, created_at: 2.days.ago)
    create_purchase(link: product, seller: @seller, price_cents: 800_000, created_at: 31.days.ago)
    create_purchase(link: product, seller: @seller, price_cents: 400_000, stripe_refunded: true, created_at: 1.day.ago)
    create_failed_purchase(link: product, seller: @seller, price_cents: 900_000, created_at: 1.day.ago)

    assert_equal 1_500_000, @seller.trailing_month_gross_sales_cents
  end

  test "refresh_high_volume_fee_eligibility! flips the cache on and off at the $20k threshold" do
    product = create_product(user: @seller)
    create_purchase(link: product, seller: @seller, price_cents: User::HIGH_VOLUME_FEE_THRESHOLD_CENTS, created_at: 1.day.ago)

    assert @seller.refresh_high_volume_fee_eligibility!
    assert @seller.reload.high_volume_fee_eligible?

    Purchase.where(seller_id: @seller.id).update_all(stripe_refunded: true)

    assert_not @seller.refresh_high_volume_fee_eligibility!
    assert_not @seller.reload.high_volume_fee_eligible?
  end

  private
    def mark_volume_eligible!(seller)
      seller.high_volume_fee_eligible = true
      seller.save!(validate: false)
    end
end
