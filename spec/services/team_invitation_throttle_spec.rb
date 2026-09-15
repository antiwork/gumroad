# frozen_string_literal: true

require "spec_helper"

describe TeamInvitationThrottle do
  let(:seller_id) { 123 }
  let(:key) { RedisKey.team_invitation_send_throttle(seller_id) }

  def seed_sends(count, age:)
    seconds, microseconds = $redis.time
    now = seconds + microseconds / 1_000_000.0
    count.times { $redis.zadd(key, now - age.to_f, SecureRandom.uuid) }
  end

  it "reserves ten sends and refuses further attempts without extending the window" do
    10.times { expect(described_class.check(seller_id)).to be_nil }
    expect($redis.zcard(key)).to eq(10)
    expect($redis.ttl(key)).to be_between(86_390, 86_400)
    history = $redis.zrange(key, 0, -1, with_scores: true)

    11.times do
      expect(described_class.check(seller_id)).to include(window: "hour", limit: 10)
    end
    expect($redis.zrange(key, 0, -1, with_scores: true)).to eq(history)
  end

  it "retains recent sends after the first send leaves the rolling hour" do
    seed_sends(1, age: 61.minutes)
    seed_sends(9, age: 2.minutes)

    expect(described_class.check(seller_id)).to be_nil
    restriction = described_class.check(seller_id)
    expect(restriction).to include(window: "hour", limit: 10)
    expect(restriction[:retry_after]).to be_between(3470, 3480)
  end

  it "retains recent sends after the first send leaves the rolling day" do
    seed_sends(1, age: 25.hours)
    seed_sends(49, age: 2.hours)

    expect(described_class.check(seller_id)).to be_nil
    expect($redis.zcard(key)).to eq(50)
    restriction = described_class.check(seller_id)
    expect(restriction).to include(window: "day", limit: 50)
    expect(restriction[:retry_after]).to be_between(79_190, 79_200)
  end

  it "returns the longer daily wait when both windows are exhausted" do
    seed_sends(40, age: 2.hours)
    seed_sends(10, age: 30.minutes)

    11.times do
      restriction = described_class.check(seller_id)
      expect(restriction).to include(window: "day", limit: 50)
      expect(restriction[:retry_after]).to be > 21.hours.to_i
    end
    expect($redis.zcard(key)).to eq(50)
  end

  it "returns the longer hourly wait when the daily allowance resets first" do
    seed_sends(40, age: 23.hours + 50.minutes)
    seed_sends(10, age: 30.minutes)

    restriction = described_class.check(seller_id)
    expect(restriction).to include(window: "hour", limit: 10)
    expect(restriction[:retry_after]).to be_between(1790, 1800)
  end

  it "admits simultaneous requests only while capacity remains" do
    results = Array.new(20) { Thread.new { described_class.check(seller_id) } }.map(&:value)

    expect(results.count(nil)).to eq(10)
    expect(results.compact.size).to eq(10)
    expect($redis.zcard(key)).to eq(10)
  end

  it "keeps sellers independent" do
    10.times { described_class.check(seller_id) }
    expect(described_class.check(seller_id + 1)).to be_nil
  end
end
