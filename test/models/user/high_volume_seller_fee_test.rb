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

  test "eligibility expires on its own at calendar-month rollover" do
    travel_to Time.utc(2026, 8, 15, 12) do
      mark_volume_eligible!(@seller)
      assert @seller.high_volume_seller_fee?
    end

    travel_to Time.utc(2026, 9, 1, 0, 5) do
      assert_not @seller.high_volume_fee_eligible?
      assert_not @seller.high_volume_seller_fee?
      assert_equal Purchase::GUMROAD_FLAT_FEE_PER_THOUSAND, @seller.gumroad_fee_per_thousand
    end
  end

  test "month_to_date_gross_sales_cents sums paid sales this month and ignores prior-month or refunded ones" do
    travel_to Time.utc(2026, 8, 15, 12) do
      product = create_product(user: @seller)
      create_purchase(link: product, seller: @seller, price_cents: 1_500_000, created_at: 2.days.ago)
      create_purchase(link: product, seller: @seller, price_cents: 800_000, created_at: Time.utc(2026, 7, 31, 23))
      create_purchase(link: product, seller: @seller, price_cents: 400_000, stripe_refunded: true, created_at: 1.day.ago)
      create_failed_purchase(link: product, seller: @seller, price_cents: 900_000, created_at: 1.day.ago)

      assert_equal 1_500_000, @seller.month_to_date_gross_sales_cents
    end
  end

  test "refresh_high_volume_fee_eligibility! flips the cache on and off at the $20k month-to-date threshold" do
    travel_to Time.utc(2026, 8, 15, 12) do
      product = create_product(user: @seller)
      create_purchase(link: product, seller: @seller, price_cents: User::HIGH_VOLUME_FEE_THRESHOLD_CENTS, created_at: 1.day.ago)

      assert @seller.refresh_high_volume_fee_eligibility!
      assert @seller.reload.high_volume_fee_eligible?
      assert_equal "2026-08", @seller.high_volume_fee_month

      Purchase.where(seller_id: @seller.id).update_all(stripe_refunded: true)

      assert_not @seller.refresh_high_volume_fee_eligibility!
      assert_not @seller.reload.high_volume_fee_eligible?
      assert_nil @seller.high_volume_fee_month
    end
  end

  test "refresh_high_volume_fee_eligibility! does not count last month's sales toward this month" do
    product = create_product(user: @seller)
    travel_to Time.utc(2026, 8, 20, 12) do
      create_purchase(link: product, seller: @seller, price_cents: User::HIGH_VOLUME_FEE_THRESHOLD_CENTS, created_at: 1.day.ago)
      assert @seller.refresh_high_volume_fee_eligibility!
    end

    travel_to Time.utc(2026, 9, 2, 12) do
      assert_not @seller.refresh_high_volume_fee_eligibility!
      assert_nil @seller.reload.high_volume_fee_month
    end
  end

  test "refresh reads the sales SUM inside the seller row lock so concurrent refreshes serialize" do
    log = []
    @seller.define_singleton_method(:with_lock) { |&blk| log << :lock; blk.call }
    @seller.define_singleton_method(:month_to_date_gross_sales_cents) { log << :sum; 0 }

    @seller.refresh_high_volume_fee_eligibility!

    assert_equal [:lock, :sum], log
  end

  test "refresh on an instance dirtied by a NULL-json_data accessor read does not raise from lock!" do
    seller = create_user
    seller.update_columns(json_data: nil)
    fresh = User.find(seller.id)
    fresh.high_volume_fee_eligible? # reading a json_data accessor on a NULL row dirties it

    assert_nothing_raised { fresh.refresh_high_volume_fee_eligibility! }
  end

  private
    def mark_volume_eligible!(seller)
      seller.high_volume_fee_month = Time.current.strftime("%Y-%m")
      seller.save!(validate: false)
    end
end
