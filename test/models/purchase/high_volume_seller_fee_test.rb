# frozen_string_literal: true

require "test_helper"

class Purchase::HighVolumeSellerFeeTest < ActiveSupport::TestCase
  setup do
    @seller = create_user
    @product = create_product(user: @seller)
    Feature.activate(:high_volume_seller_fee)
  end

  teardown do
    Feature.deactivate(:high_volume_seller_fee)
  end

  test "gumroad_flat_fee_per_thousand is 5% for an eligible seller when the flag is on" do
    mark_volume_eligible!(@seller)
    purchase = create_purchase(link: @product, seller: @seller, purchase_state: "in_progress", price_cents: 1000)

    assert_equal User::HIGH_VOLUME_FEE_PER_THOUSAND, purchase.send(:gumroad_flat_fee_per_thousand)
  end

  test "gumroad_flat_fee_per_thousand stays 10% when the flag is off" do
    Feature.deactivate(:high_volume_seller_fee)
    mark_volume_eligible!(@seller)
    purchase = create_purchase(link: @product, seller: @seller, purchase_state: "in_progress", price_cents: 1000)

    assert_equal Purchase::GUMROAD_FLAT_FEE_PER_THOUSAND, purchase.send(:gumroad_flat_fee_per_thousand)
  end

  test "a negotiated custom fee still wins over the volume rate" do
    mark_volume_eligible!(@seller)
    @seller.update!(custom_fee_per_thousand: 40)
    purchase = create_purchase(link: @product, seller: @seller, purchase_state: "in_progress", price_cents: 10_000)
    purchase.send(:calculate_custom_fee_per_thousand)

    assert_equal 40, purchase.custom_fee_per_thousand
  end

  test "discover fee is unchanged for an eligible seller" do
    mark_volume_eligible!(@seller)
    purchase = create_purchase(link: @product, seller: @seller, purchase_state: "in_progress", price_cents: 10_000)
    purchase.stubs(:charge_discover_fee?).returns(true)
    purchase.send(:calculate_custom_fee_per_thousand)

    assert_nil purchase.custom_fee_per_thousand
  end

  test "a successful purchase enqueues an eligibility refresh for the seller" do
    create_purchase(link: @product, seller: @seller, price_cents: 1000)

    assert RefreshHighVolumeSellerFeeEligibilityJob.jobs.any? { |job| job["args"] == [@seller.id] }
  end

  test "a full refund enqueues an eligibility refresh for the seller" do
    purchase = create_purchase(link: @product, seller: @seller, price_cents: 1000)
    RefreshHighVolumeSellerFeeEligibilityJob.clear

    purchase.update!(stripe_refunded: true)

    assert RefreshHighVolumeSellerFeeEligibilityJob.jobs.any? { |job| job["args"] == [@seller.id] }
  end

  test "a refund reversal enqueues an eligibility refresh for the seller" do
    purchase = create_purchase(link: @product, seller: @seller, price_cents: 1000)
    purchase.update!(stripe_refunded: true)
    RefreshHighVolumeSellerFeeEligibilityJob.clear

    purchase.update!(stripe_refunded: false)

    assert RefreshHighVolumeSellerFeeEligibilityJob.jobs.any? { |job| job["args"] == [@seller.id] }
  end

  private
    def mark_volume_eligible!(seller)
      seller.high_volume_fee_eligible = true
      seller.save!(validate: false)
    end
end
