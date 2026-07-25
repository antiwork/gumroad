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

  describe "when Sidekiq gives up retrying" do
    it "hands the computation claim back so requests can attempt the sum again" do
      affiliate = create(:direct_affiliate, affiliate_basis_points: 1000)
      Rails.cache.clear
      Rails.cache.write(AffiliateEarningsCache.compute_lock_key(affiliate), true, expires_in: 1.hour)

      described_class.sidekiq_retries_exhausted_block.call({ "args" => [affiliate.id] }, StandardError.new)

      expect(Rails.cache.read(AffiliateEarningsCache.compute_lock_key(affiliate))).to be_nil
    end

    it "does not blow up when the affiliate is gone" do
      expect do
        described_class.sidekiq_retries_exhausted_block.call({ "args" => [0] }, StandardError.new)
      end.not_to raise_error
    end
  end
end
