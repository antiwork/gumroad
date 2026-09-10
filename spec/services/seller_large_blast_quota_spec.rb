# frozen_string_literal: true

require "spec_helper"

describe SellerLargeBlastQuota, :freeze_time do
  let(:seller_id) { 1888878 }
  let(:first_blast) { 11 }
  let(:second_blast) { 22 }

  after do
    $redis.del(RedisKey.seller_large_blast_quota(seller_id, Date.current))
    $redis.del(RedisKey.seller_large_blast_threshold)
    $redis.del(RedisKey.seller_large_blast_deferral_window_start_seconds)
    $redis.del(RedisKey.seller_large_blast_deferral_window_length_seconds)
  end

  it "lets any send under the threshold through without claiming the day" do
    expect(described_class.allow?(seller_id:, blast_id: first_blast, recipient_count: described_class::DEFAULT_THRESHOLD - 1)).to eq(true)
    expect($redis.get(RedisKey.seller_large_blast_quota(seller_id, Date.current))).to be_nil
  end

  it "lets the first large send through and holds the rest of the day" do
    expect(described_class.allow?(seller_id:, blast_id: first_blast, recipient_count: described_class::DEFAULT_THRESHOLD)).to eq(true)
    expect(described_class.allow?(seller_id:, blast_id: second_blast, recipient_count: described_class::DEFAULT_THRESHOLD)).to eq(false)
  end

  it "lets the same blast retry after it already claimed the day" do
    expect(described_class.allow?(seller_id:, blast_id: first_blast, recipient_count: described_class::DEFAULT_THRESHOLD)).to eq(true)
    expect(described_class.allow?(seller_id:, blast_id: first_blast, recipient_count: described_class::DEFAULT_THRESHOLD)).to eq(true)
  end

  it "does not treat a workflow post and a one-off blast as the same claim when their ids match" do
    expect(described_class.allow?(seller_id:, kind: "post_blast", blast_id: first_blast, recipient_count: described_class::DEFAULT_THRESHOLD)).to eq(true)
    expect(described_class.allow?(seller_id:, kind: "workflow", blast_id: first_blast, recipient_count: described_class::DEFAULT_THRESHOLD)).to eq(false)
    expect(described_class.allow?(seller_id:, kind: "post_blast", blast_id: first_blast, recipient_count: described_class::DEFAULT_THRESHOLD)).to eq(true)
  end

  it "does not admit a large send when Redis is down" do
    allow($redis).to receive(:set).and_raise(Redis::CannotConnectError, "no connection")
    expect(ErrorNotifier).to receive(:notify)

    expect(described_class.allow?(seller_id:, blast_id: first_blast, recipient_count: described_class::DEFAULT_THRESHOLD)).to eq(false)
  end

  describe ".deferred_run_at" do
    let(:window_start) { Time.zone.tomorrow.beginning_of_day + described_class::DEFERRAL_WINDOW_START }
    let(:window_end) { window_start + described_class::DEFERRAL_WINDOW_LENGTH }

    it "lands inside the overnight window, past the UTC midnight that frees the next day's slot" do
      100.times do
        run_at = described_class.deferred_run_at
        expect(run_at).to be >= window_start
        expect(run_at).to be < window_end
        expect(run_at.to_date).to eq(Date.current + 1)
      end
    end

    it "spreads sends across the window instead of stacking them on one instant" do
      run_ats = Array.new(50) { described_class.deferred_run_at }

      expect(run_ats.uniq.size).to be > 1
      expect(run_ats.max - run_ats.min).to be > 1.hour
    end

    it "honors a Redis override of the window" do
      $redis.set(RedisKey.seller_large_blast_deferral_window_start_seconds, 8.hours.to_i)
      $redis.set(RedisKey.seller_large_blast_deferral_window_length_seconds, 1.hour.to_i)

      run_at = described_class.deferred_run_at

      expect(run_at).to be >= Time.zone.tomorrow.beginning_of_day + 8.hours
      expect(run_at).to be < Time.zone.tomorrow.beginning_of_day + 9.hours
    end

    it "falls back to the default window when Redis is down" do
      allow($redis).to receive(:get).and_raise(Redis::CannotConnectError, "no connection")

      run_at = described_class.deferred_run_at

      expect(run_at).to be >= window_start
      expect(run_at).to be < window_end
    end
  end

  it "opens a new slot the next day" do
    expect(described_class.allow?(seller_id:, blast_id: first_blast, recipient_count: described_class::DEFAULT_THRESHOLD)).to eq(true)

    travel 1.day
    expect(described_class.allow?(seller_id:, blast_id: second_blast, recipient_count: described_class::DEFAULT_THRESHOLD)).to eq(true)
  end
end
