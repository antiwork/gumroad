# frozen_string_literal: true

require "spec_helper"

describe AffiliateEarningsCache do
  let(:affiliate) { create(:direct_affiliate, affiliate_basis_points: 1000) }

  before do
    Rails.cache.clear
  end

  # The commission on a purchase is only computed when the purchase runs through
  # the affiliate's own product, which is more setup than these specs need — they
  # care about how the sum is fetched, not how it is earned. Setting the credit
  # directly gives a known amount to sum.
  def create_purchase_earning(cents)
    purchase = create(:purchase, affiliate:, purchase_state: "successful", price_cents: 100)
    purchase.update_column(:affiliate_credit_cents, cents)
    purchase
  end

  describe ".fetch" do
    it "computes the sum, caches it, and serves later calls from the cache" do
      create_purchase_earning(10)

      expect(described_class.fetch(affiliate)).to eq 10
      expect(Rails.cache.read(described_class.cache_key(affiliate))[:cents]).to eq 10

      # A second call within the freshness window must not re-run the aggregate.
      expect_any_instance_of(Affiliate).not_to receive(:total_cents_earned)
      expect(described_class.fetch(affiliate)).to eq 10
    end

    it "caches a zero sum instead of recomputing it on every request" do
      expect(described_class.fetch(affiliate)).to eq 0

      expect_any_instance_of(Affiliate).not_to receive(:total_cents_earned)
      expect(described_class.fetch(affiliate)).to eq 0
    end

    it "applies a statement timeout to the in-request computation" do
      expect(affiliate).to receive(:total_cents_earned).with(timeout_ms: described_class::REQUEST_TIMEOUT_MS).and_return(42)

      expect(described_class.fetch(affiliate)).to eq 42
    end

    context "when the in-request computation times out" do
      before do
        allow(affiliate).to receive(:total_cents_earned).with(timeout_ms: anything)
          .and_raise(ActiveRecord::QueryCanceled.new("Query execution was interrupted, maximum statement execution time exceeded"))
      end

      it "returns nil rather than a wrong number and schedules a background refresh" do
        expect do
          expect(described_class.fetch(affiliate)).to be_nil
        end.to change { RefreshAffiliateEarningsWorker.jobs.size }.by(1)

        expect(RefreshAffiliateEarningsWorker.jobs.last["args"]).to eq [affiliate.id]
      end

      it "does not poison the cache, so a later successful computation is stored" do
        described_class.fetch(affiliate)
        expect(Rails.cache.read(described_class.cache_key(affiliate))).to be_nil
      end
    end

    it "re-raises database errors that are not statement timeouts" do
      allow(affiliate).to receive(:total_cents_earned).with(timeout_ms: anything)
        .and_raise(ActiveRecord::StatementInvalid.new("Unknown column 'nope'"))

      expect { described_class.fetch(affiliate) }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "serves a stale value immediately and refreshes it in the background" do
      Rails.cache.write(
        described_class.cache_key(affiliate),
        { cents: 500, computed_at: (described_class::STALE_AFTER + 1.minute).ago },
        expires_in: described_class::CACHE_TTL
      )

      expect_any_instance_of(Affiliate).not_to receive(:total_cents_earned)

      expect do
        expect(described_class.fetch(affiliate)).to eq 500
      end.to change { RefreshAffiliateEarningsWorker.jobs.size }.by(1)
    end

    it "does not schedule a refresh for a fresh value" do
      described_class.refresh!(affiliate)

      expect do
        described_class.fetch(affiliate)
      end.not_to change { RefreshAffiliateEarningsWorker.jobs.size }
    end
  end

  describe ".refresh!" do
    it "computes the sum with no statement timeout and caches it" do
      create_purchase_earning(139)

      expect(affiliate).to receive(:total_cents_earned).with(no_args).and_call_original

      expect(described_class.refresh!(affiliate)).to eq 139
      expect(Rails.cache.read(described_class.cache_key(affiliate))[:cents]).to eq 139
    end
  end
end
