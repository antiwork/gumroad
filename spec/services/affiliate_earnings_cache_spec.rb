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
        # MySQL reports a MAX_EXECUTION_TIME abort as error 3024, which Rails
        # raises as StatementTimeout — this is the exception the production path
        # actually sees, so assert against it rather than a sibling class.
        allow(affiliate).to receive(:total_cents_earned).with(timeout_ms: anything)
          .and_raise(ActiveRecord::StatementTimeout.new("Query execution was interrupted, maximum statement execution time exceeded"))
      end

      it "returns nil rather than a wrong number and schedules a background refresh" do
        expect do
          expect(described_class.fetch(affiliate)).to be_nil
        end.to change { RefreshAffiliateEarningsJob.jobs.size }.by(1)

        expect(RefreshAffiliateEarningsJob.jobs.last["args"]).to eq [affiliate.id]
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

    it "also treats a connection-level cancellation of the query as a timeout" do
      allow(affiliate).to receive(:total_cents_earned).with(timeout_ms: anything)
        .and_raise(ActiveRecord::QueryCanceled.new("canceling statement due to statement timeout"))

      expect do
        expect(described_class.fetch(affiliate)).to be_nil
      end.to change { RefreshAffiliateEarningsJob.jobs.size }.by(1)
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
      end.to change { RefreshAffiliateEarningsJob.jobs.size }.by(1)
    end

    it "does not schedule a refresh for a fresh value" do
      described_class.refresh!(affiliate)

      expect do
        described_class.fetch(affiliate)
      end.not_to change { RefreshAffiliateEarningsJob.jobs.size }
    end

    context "when another request is already computing the same affiliate's sum" do
      before do
        Rails.cache.write(described_class.compute_lock_key(affiliate), true, expires_in: described_class::COMPUTE_LOCK_TTL)
      end

      it "does not run a second copy of the aggregate, and does not queue one either" do
        expect_any_instance_of(Affiliate).not_to receive(:total_cents_earned)

        expect do
          expect(described_class.fetch(affiliate)).to be_nil
        end.not_to change { RefreshAffiliateEarningsJob.jobs.size }
      end
    end

    it "releases its claim once the value is cached, so a later cold miss can compute again" do
      create_purchase_earning(10)

      expect(described_class.fetch(affiliate)).to eq 10
      expect(Rails.cache.read(described_class.compute_lock_key(affiliate))).to be_nil

      Rails.cache.delete(described_class.cache_key(affiliate))
      expect(described_class.fetch(affiliate)).to eq 10
    end

    it "holds the claim after a timeout so the next requests skip the slow path" do
      allow(affiliate).to receive(:total_cents_earned).with(timeout_ms: anything)
        .and_raise(ActiveRecord::StatementTimeout.new("Query execution was interrupted, maximum statement execution time exceeded"))

      expect(described_class.fetch(affiliate)).to be_nil
      expect(Rails.cache.read(described_class.compute_lock_key(affiliate))).to be_present
    end

    it "keeps holding it long enough to cover the background job it handed the work to" do
      allow(affiliate).to receive(:total_cents_earned).with(timeout_ms: anything)
        .and_raise(ActiveRecord::StatementTimeout.new("Query execution was interrupted, maximum statement execution time exceeded"))

      expect(described_class.fetch(affiliate)).to be_nil

      # The claim was taken for a three-second attempt, but it now has to outlast
      # a queue wait plus an unbounded aggregate. If it lapsed at the shorter
      # window, the next request would start a competing scan.
      travel_to(described_class::COMPUTE_LOCK_TTL.from_now + 1.second) do
        expect(Rails.cache.read(described_class.compute_lock_key(affiliate))).to be_present
      end
    end

    it "hands the claim back when the computation fails for a reason other than a timeout" do
      allow(affiliate).to receive(:total_cents_earned).with(timeout_ms: anything)
        .and_raise(ActiveRecord::StatementInvalid.new("Unknown column 'nope'"))

      expect { described_class.fetch(affiliate) }.to raise_error(ActiveRecord::StatementInvalid)
      expect(Rails.cache.read(described_class.compute_lock_key(affiliate))).to be_nil
    end
  end

  describe ".refresh!" do
    it "computes the sum with the background time limit and caches it" do
      create_purchase_earning(139)

      # The background limit has to be larger than the request one, and larger
      # than the session-wide five minute cap the connection is opened with, or
      # the job would be no more able to finish a heavy sum than the request was.
      expect(described_class::BACKGROUND_TIMEOUT_MS).to be > described_class::REQUEST_TIMEOUT_MS
      expect(described_class::BACKGROUND_TIMEOUT_MS).to be > 5.minutes.in_milliseconds

      expect(affiliate).to receive(:total_cents_earned).with(timeout_ms: described_class::BACKGROUND_TIMEOUT_MS).and_call_original

      expect(described_class.refresh!(affiliate)).to eq 139
      expect(Rails.cache.read(described_class.cache_key(affiliate))[:cents]).to eq 139
    end

    it "claims nothing, so warming a value from a console cannot park the page on the calculating state" do
      # `refresh!` is the plain recomputation, with no ownership attached. Only
      # the background job's entry point takes the claim, because only it has a
      # retry behind it to finish the work.
      described_class.refresh!(affiliate)

      expect(Rails.cache.read(described_class.compute_lock_key(affiliate))).to be_nil
    end
  end

  describe ".refresh_unless_fresh!" do
    it "skips the aggregate when a fresh value is already cached" do
      described_class.refresh!(affiliate)

      expect_any_instance_of(Affiliate).not_to receive(:total_cents_earned)
      expect(described_class.refresh_unless_fresh!(affiliate)).to eq 0
    end

    it "recomputes when nothing is cached" do
      create_purchase_earning(21)

      expect(described_class.refresh_unless_fresh!(affiliate)).to eq 21
      expect(Rails.cache.read(described_class.cache_key(affiliate))[:cents]).to eq 21
    end

    it "re-arms the claim when the aggregate starts, so a long queue wait cannot let it lapse mid-run" do
      # Stands in for a claim that was written when the request handed the work
      # over and has since spent most of its window waiting in the queue.
      Rails.cache.write(described_class.compute_lock_key(affiliate), true, expires_in: 30.seconds)

      claim_held_during_run = nil
      allow(affiliate).to receive(:total_cents_earned) do
        # A heavy sum can run for many minutes. If the claim still carried the
        # window it was written with before the queue wait, it would lapse right
        # here and let a cold request start a competing scan.
        travel_to(2.minutes.from_now) do
          claim_held_during_run = Rails.cache.read(described_class.compute_lock_key(affiliate)).present?
        end
        7
      end

      expect(described_class.refresh_unless_fresh!(affiliate)).to eq 7
      expect(claim_held_during_run).to be true
    end

    it "claims the computation even when the handoff claim already expired in the queue" do
      # The worst case for this endpoint is the affiliate whose sum is slowest,
      # and that job also waits behind the longest low-priority queue — long
      # enough that the claim the request handed over can lapse before the job is
      # picked up. The run still has to hold requests back while it scans, so it
      # takes the claim itself rather than leaving the window uncovered.
      claim_held_during_run = nil
      allow(affiliate).to receive(:total_cents_earned) do
        claim_held_during_run = Rails.cache.read(described_class.compute_lock_key(affiliate)).present?
        7
      end

      expect(Rails.cache.read(described_class.compute_lock_key(affiliate))).to be_nil
      expect(described_class.refresh_unless_fresh!(affiliate)).to eq 7
      expect(claim_held_during_run).to be true
    end

    it "does not leave a claim behind once it has cached a value" do
      # The claim exists to stop a second scan while this one runs, so having
      # written the number it must go — otherwise the page would keep showing the
      # calculating state for a value that is ready.
      expect(described_class.refresh_unless_fresh!(affiliate)).to eq 0

      expect(Rails.cache.read(described_class.compute_lock_key(affiliate))).to be_nil
    end

    it "releases the claim a timed-out request handed over, so requests stop showing the calculating state" do
      Rails.cache.write(described_class.compute_lock_key(affiliate), true, expires_in: described_class::BACKGROUND_HANDOFF_LOCK_TTL)

      described_class.refresh_unless_fresh!(affiliate)

      expect(Rails.cache.read(described_class.compute_lock_key(affiliate))).to be_nil
    end

    it "keeps the claim when the recomputation fails, so a retry is the only thing computing the sum" do
      Rails.cache.write(described_class.compute_lock_key(affiliate), true, expires_in: described_class::BACKGROUND_HANDOFF_LOCK_TTL)
      allow(affiliate).to receive(:total_cents_earned).and_raise(ActiveRecord::StatementTimeout)

      expect { described_class.refresh_unless_fresh!(affiliate) }.to raise_error(ActiveRecord::StatementTimeout)

      # Sidekiq still has retries left for this job, so releasing here would let
      # the next request start its own scan alongside the pending retry.
      expect(Rails.cache.read(described_class.compute_lock_key(affiliate))).to be_present
      expect(Rails.cache.read(described_class.cache_key(affiliate))).to be_nil
    end

    it "keeps a claim for the pending retry even when the handoff claim expired in the queue" do
      allow(affiliate).to receive(:total_cents_earned).and_raise(ActiveRecord::StatementTimeout)

      expect(Rails.cache.read(described_class.compute_lock_key(affiliate))).to be_nil
      expect { described_class.refresh_unless_fresh!(affiliate) }.to raise_error(ActiveRecord::StatementTimeout)

      # The retry is the only thing that is going to compute this sum, so it stays
      # the owner. The job's retries-exhausted hook is what finally hands the
      # computation back to the request path.
      expect(Rails.cache.read(described_class.compute_lock_key(affiliate))).to be_present
    end

    it "recomputes when the cached value is stale" do
      create_purchase_earning(21)
      Rails.cache.write(
        described_class.cache_key(affiliate),
        { cents: 500, computed_at: (described_class::STALE_AFTER + 1.minute).ago },
        expires_in: described_class::CACHE_TTL
      )

      expect(described_class.refresh_unless_fresh!(affiliate)).to eq 21
    end

    it "does not scan while another worker is already running the aggregate" do
      # Two stale-page reloads can produce two refresh jobs, and the job's
      # queue-level uniqueness lock does not stop the second from starting once
      # the first is in flight. Only one of them may scan the purchase history.
      Rails.cache.write(
        described_class.cache_key(affiliate),
        { cents: 500, computed_at: (described_class::STALE_AFTER + 1.minute).ago },
        expires_in: described_class::CACHE_TTL
      )
      Rails.cache.write(described_class.background_run_lock_key(affiliate), true, expires_in: 1.minute)

      expect(affiliate).not_to receive(:total_cents_earned)
      # The stale number is still the best answer available, so the losing run
      # hands that back rather than nil.
      expect(described_class.refresh_unless_fresh!(affiliate)).to eq 500
    end

    it "returns nothing rather than a wrong number when it loses the lock with no value cached" do
      Rails.cache.write(described_class.background_run_lock_key(affiliate), true, expires_in: 1.minute)

      expect(affiliate).not_to receive(:total_cents_earned)
      expect(described_class.refresh_unless_fresh!(affiliate)).to be_nil
    end

    it "leaves the request-facing claim alone when it loses the lock" do
      # The worker that holds the lock is computing right now, so requests should
      # keep waiting for it. Releasing the claim here would let one start its own
      # bounded scan next to that run.
      Rails.cache.write(described_class.background_run_lock_key(affiliate), true, expires_in: 1.minute)
      Rails.cache.write(described_class.compute_lock_key(affiliate), true, expires_in: described_class::BACKGROUND_HANDOFF_LOCK_TTL)

      described_class.refresh_unless_fresh!(affiliate)

      expect(Rails.cache.read(described_class.compute_lock_key(affiliate))).to be_present
    end

    it "holds the run lock while scanning and releases it afterwards" do
      lock_held_during_run = nil
      allow(affiliate).to receive(:total_cents_earned) do
        lock_held_during_run = Rails.cache.read(described_class.background_run_lock_key(affiliate)).present?
        7
      end

      expect(described_class.refresh_unless_fresh!(affiliate)).to eq 7

      expect(lock_held_during_run).to be true
      expect(Rails.cache.read(described_class.background_run_lock_key(affiliate))).to be_nil
    end

    it "releases the run lock when the aggregate fails, so the retry can take it" do
      # Unlike the request-facing claim, which deliberately survives a failed run
      # so the pending retry stays the owner, this lock guards a single attempt.
      # Holding it past the failure would make the retry a no-op until it expired.
      allow(affiliate).to receive(:total_cents_earned).and_raise(ActiveRecord::StatementTimeout)

      expect { described_class.refresh_unless_fresh!(affiliate) }.to raise_error(ActiveRecord::StatementTimeout)

      expect(Rails.cache.read(described_class.background_run_lock_key(affiliate))).to be_nil
    end
  end
end
