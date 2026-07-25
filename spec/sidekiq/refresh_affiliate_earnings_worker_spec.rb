# frozen_string_literal: true

require "spec_helper"

describe RefreshAffiliateEarningsWorker do
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

  it "does nothing when the affiliate no longer exists" do
    expect { described_class.new.perform(0) }.not_to raise_error
  end
end
