# frozen_string_literal: true

require "test_helper"

class RefreshHighVolumeSellerFeeEligibilityJobTest < ActiveSupport::TestCase
  test "perform with a seller_id refreshes that seller" do
    seller = create_user
    product = create_product(user: seller)
    create_purchase(link: product, seller: seller, price_cents: User::HIGH_VOLUME_FEE_THRESHOLD_CENTS, created_at: 1.day.ago)

    RefreshHighVolumeSellerFeeEligibilityJob.new.perform(seller.id)

    assert seller.reload.high_volume_fee_eligible?
  end

  test "seller_ids_to_refresh includes qualifying and flagged sellers, not below-threshold ones" do
    # Qualifying purely on window GMV: no sale yesterday, no cache populated.
    qualifying = create_user
    qualifying_product = create_product(user: qualifying)
    create_purchase(link: qualifying_product, seller: qualifying, price_cents: User::HIGH_VOLUME_FEE_THRESHOLD_CENTS, created_at: 10.days.ago)

    flagged = create_user
    flagged.high_volume_fee_eligible = true
    flagged.save!(validate: false)

    below_threshold = create_user
    below_product = create_product(user: below_threshold)
    create_purchase(link: below_product, seller: below_threshold, price_cents: 100, created_at: 2.hours.ago)

    stale = create_user

    ids = RefreshHighVolumeSellerFeeEligibilityJob.new.send(:seller_ids_to_refresh)
    assert_includes ids, qualifying.id
    assert_includes ids, flagged.id
    assert_not_includes ids, below_threshold.id
    assert_not_includes ids, stale.id
  end

  test "seller_ids_to_refresh sums across purchases and ignores refunded and out-of-window sales" do
    seller = create_user
    product = create_product(user: seller)
    half = User::HIGH_VOLUME_FEE_THRESHOLD_CENTS / 2
    create_purchase(link: product, seller: seller, price_cents: half, created_at: 5.days.ago)
    create_purchase(link: product, seller: seller, price_cents: half, created_at: 20.days.ago)

    refunded_out = create_user
    refunded_product = create_product(user: refunded_out)
    refunded = create_purchase(link: refunded_product, seller: refunded_out, price_cents: User::HIGH_VOLUME_FEE_THRESHOLD_CENTS, created_at: 5.days.ago)
    refunded.update_columns(stripe_refunded: true)

    aged_out = create_user
    aged_product = create_product(user: aged_out)
    create_purchase(link: aged_product, seller: aged_out, price_cents: User::HIGH_VOLUME_FEE_THRESHOLD_CENTS, created_at: 40.days.ago)

    ids = RefreshHighVolumeSellerFeeEligibilityJob.new.send(:seller_ids_to_refresh)
    assert_includes ids, seller.id
    assert_not_includes ids, refunded_out.id
    assert_not_includes ids, aged_out.id
  end
end
