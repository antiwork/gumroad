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

  test "discover sales keep the full rate: the volume base does not apply when the discover fee is charged" do
    mark_volume_eligible!(@seller)
    purchase = create_purchase(link: @product, seller: @seller, purchase_state: "in_progress", price_cents: 10_000)
    purchase.stubs(:charge_discover_fee?).returns(true)

    assert_equal Purchase::GUMROAD_FLAT_FEE_PER_THOUSAND, purchase.send(:gumroad_flat_fee_per_thousand)
  end

  test "a sale that crosses the threshold makes the seller eligible before the next fee calculation" do
    RefreshHighVolumeSellerFeeEligibilityJob.clear
    create_purchase(link: @product, seller: @seller, price_cents: 2_000_000)

    assert @seller.reload.high_volume_fee_eligible?
    assert_empty RefreshHighVolumeSellerFeeEligibilityJob.jobs
  end

  test "a successful sale for an already-eligible seller enqueues the async refresh" do
    mark_volume_eligible!(@seller)
    RefreshHighVolumeSellerFeeEligibilityJob.clear
    create_purchase(link: @product, seller: @seller, price_cents: 1000)

    assert RefreshHighVolumeSellerFeeEligibilityJob.jobs.any? { |job| job["args"] == [@seller.id] }
  end

  test "a successful sale keeps the async pre-warm when the flag is off" do
    Feature.deactivate(:high_volume_seller_fee)
    RefreshHighVolumeSellerFeeEligibilityJob.clear
    create_purchase(link: @product, seller: @seller, price_cents: 2_000_000)

    assert_not @seller.reload.high_volume_fee_eligible?
    assert RefreshHighVolumeSellerFeeEligibilityJob.jobs.any? { |job| job["args"] == [@seller.id] }
  end

  test "a full refund clears eligibility synchronously so the next sale cannot use the stale 5% rate" do
    purchase = create_purchase(link: @product, seller: @seller, price_cents: 2_000_000)
    @seller.refresh_high_volume_fee_eligibility!
    assert @seller.high_volume_fee_eligible?
    RefreshHighVolumeSellerFeeEligibilityJob.clear

    purchase.update!(stripe_refunded: true)

    assert_not @seller.reload.high_volume_fee_eligible?
    assert_empty RefreshHighVolumeSellerFeeEligibilityJob.jobs
  end

  test "a refund reversal restores eligibility synchronously" do
    purchase = create_purchase(link: @product, seller: @seller, price_cents: 2_000_000)
    purchase.update!(stripe_refunded: true)
    @seller.reload
    assert_not @seller.high_volume_fee_eligible?
    RefreshHighVolumeSellerFeeEligibilityJob.clear

    purchase.update!(stripe_refunded: false)

    assert @seller.reload.high_volume_fee_eligible?
    assert_empty RefreshHighVolumeSellerFeeEligibilityJob.jobs
  end

  test "a refund still commits when the synchronous refresh raises, falling back to the async job" do
    purchase = create_purchase(link: @product, seller: @seller, price_cents: 1000)
    RefreshHighVolumeSellerFeeEligibilityJob.clear
    User.any_instance.stubs(:refresh_high_volume_fee_eligibility!).raises(StandardError, "boom")

    purchase.update!(stripe_refunded: true)

    assert purchase.reload.stripe_refunded?
    assert RefreshHighVolumeSellerFeeEligibilityJob.jobs.any? { |job| job["args"] == [@seller.id] }
  end

  test "a refund with no seller does not enqueue the nightly full-fleet refresh" do
    purchase = create_purchase(link: @product, seller: @seller, price_cents: 1000)
    purchase.update_columns(seller_id: nil)
    purchase.reload
    RefreshHighVolumeSellerFeeEligibilityJob.clear

    purchase.send(:refresh_high_volume_fee_eligibility)
    purchase.send(:enqueue_high_volume_fee_eligibility_refresh)

    assert_empty RefreshHighVolumeSellerFeeEligibilityJob.jobs
  end

  test "paypal order fee uses the volume rate for an eligible seller on a direct sale only" do
    mark_volume_eligible!(@seller)

    direct = @product.gumroad_amount_for_paypal_order(amount_cents: 10_000)
    recommended = @product.gumroad_amount_for_paypal_order(amount_cents: 10_000, was_recommended: true)

    assert_equal 10_000 * User::HIGH_VOLUME_FEE_PER_THOUSAND / 1000, direct
    assert_equal 10_000 * (Purchase::GUMROAD_FLAT_FEE_PER_THOUSAND + @product.discover_fee_per_thousand - Purchase::GUMROAD_DISCOVER_EXTRA_FEE_PER_THOUSAND) / 1000, recommended
  end

  test "paypal order fee is unchanged when the flag is off, even with a custom fee" do
    Feature.deactivate(:high_volume_seller_fee)
    mark_volume_eligible!(@seller)
    @seller.update!(custom_fee_per_thousand: 40)

    assert_equal 10_000 * Purchase::GUMROAD_FLAT_FEE_PER_THOUSAND / 1000,
                 @product.gumroad_amount_for_paypal_order(amount_cents: 10_000)
  end

  private
    def mark_volume_eligible!(seller)
      seller.high_volume_fee_month = Time.current.strftime("%Y-%m")
      seller.save!(validate: false)
    end
end
