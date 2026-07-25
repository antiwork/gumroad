# frozen_string_literal: true

require "spec_helper"

describe RefreshAffiliateEarningsJob do
  it "recomputes and caches the affiliate's lifetime earnings" do
    affiliate = create(:direct_affiliate, affiliate_basis_points: 1000)
    # Set the commission directly rather than routing a purchase through the
    # affiliate's own product, which is more setup than this spec needs.
    create(:purchase, affiliate:, purchase_state: "successful", price_cents: 100)
      .update_column(:affiliate_credit_cents, 10)
    Rails.cache.clear

    described_class.new.perform(affiliate.id)

    expect(Rails.cache.read(AffiliateEarningsCache.cache_key(affiliate))[:cents]).to eq 10
  end

  it "skips the recomputation when a fresh value is already cached" do
    affiliate = create(:direct_affiliate, affiliate_basis_points: 1000)
    Rails.cache.clear
    AffiliateEarningsCache.refresh!(affiliate)

    # The uniqueness lock only collapses queued jobs, so a second run can start
    # while one is in flight. Re-reading the cache is what keeps that from
    # becoming a duplicate unbounded scan.
    expect_any_instance_of(Affiliate).not_to receive(:total_cents_earned)

    described_class.new.perform(affiliate.id)
  end

  it "does nothing when the affiliate no longer exists" do
    expect { described_class.new.perform(0) }.not_to raise_error
  end
end
