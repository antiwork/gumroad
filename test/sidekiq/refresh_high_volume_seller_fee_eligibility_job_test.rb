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

  test "seller_ids_to_refresh includes recent sellers and currently flagged sellers" do
    recent = create_user
    product = create_product(user: recent)
    create_purchase(link: product, seller: recent, price_cents: 100, created_at: 2.hours.ago)

    flagged = create_user
    flagged.high_volume_fee_eligible = true
    flagged.save!(validate: false)

    stale = create_user

    ids = RefreshHighVolumeSellerFeeEligibilityJob.new.send(:seller_ids_to_refresh)
    assert_includes ids, recent.id
    assert_includes ids, flagged.id
    assert_not_includes ids, stale.id
  end
end
