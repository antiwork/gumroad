# frozen_string_literal: true

require "spec_helper"

describe UpdatePurchaseHealthcheckThresholdJob do
  let(:redis_key) { RedisKey.min_successful_purchases_in_last_10_minutes }
  let(:job) { described_class.new }

  after { $redis.del(redis_key) }

  def stub_baseline_counts(counts)
    allow(job).to receive(:successful_count_in).and_return(*counts)
  end

  it "sets the threshold to half the median of the same window on the prior 7 days" do
    stub_baseline_counts([210, 610, 400, 600, 404, 220, 402]) # median 402

    job.perform

    expect($redis.get(redis_key).to_i).to eq(201)
  end

  it "queries the 10-minute window ending at the same clock time on each of the prior 7 days" do
    queried_ranges = []
    allow(job).to receive(:successful_count_in) { |range| queried_ranges << range; 0 }

    now = Time.current
    travel_to(now) { job.perform }

    expect(queried_ranges.size).to eq(7)
    queried_ranges.each_with_index do |range, i|
      expect(range.last).to be_within(1.second).of(now - (i + 1).days)
      expect(range.last - range.first).to eq(10.minutes)
    end
  end

  it "never sets the threshold below the floor" do
    stub_baseline_counts([0, 0, 0, 0, 0, 0, 0])

    job.perform

    expect($redis.get(redis_key).to_i).to eq(described_class::MIN_THRESHOLD)
  end

  it "sets a TTL so a stalled job fails the healthcheck closed instead of freezing a stale threshold" do
    stub_baseline_counts([1000] * 7)

    job.perform

    ttl = $redis.ttl(redis_key)
    expect(ttl).to be > 0
    expect(ttl).to be <= described_class::THRESHOLD_TTL.to_i
  end

  it "bounds the until_executed lock so a SIGKILLed run cannot mute the refresh forever" do
    lock_ttl = described_class.sidekiq_options["lock_ttl"]

    expect(described_class.sidekiq_options["lock"]).to eq(:until_executed)
    expect(lock_ttl).to be_present
    # Must expire well before the threshold key it refreshes, or a stranded lock
    # takes the healthcheck down with it.
    expect(lock_ttl).to be < described_class::THRESHOLD_TTL.to_i
  end

  it "counts only successful purchases inside the baseline window" do
    create(:purchase, purchase_state: "successful", created_at: 1.day.ago - 5.minutes)
    create(:purchase, purchase_state: "successful", created_at: 1.day.ago - 30.minutes)
    create(:purchase, purchase_state: "failed", created_at: 1.day.ago - 5.minutes)

    count = job.send(:successful_count_in, (1.day.ago - 10.minutes)..1.day.ago)

    expect(count).to eq(1)
  end
end
