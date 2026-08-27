# frozen_string_literal: true

require "spec_helper"

describe WorkflowSellerFanoutLock do
  let(:seller_id) { 1888877 }

  after { $redis.del(RedisKey.workflow_seller_fanout_lock(seller_id)) }

  it "gives the second acquire nothing while the first is held" do
    first = described_class.acquire(seller_id)
    second = described_class.acquire(seller_id)

    expect(first).to be_present
    expect(second).to be_nil

    first.release
    expect(described_class.acquire(seller_id)).to be_present
  end

  it "does not grant a lock when Redis is down" do
    allow($redis).to receive(:set).and_raise(Redis::CannotConnectError, "no connection")
    expect(ErrorNotifier).to receive(:notify)

    expect(described_class.acquire(seller_id)).to be_nil
  end

  it "treats a renewal error as lost ownership" do
    lock = described_class.acquire(seller_id)
    allow($redis).to receive(:eval).and_raise(Redis::CannotConnectError, "no connection")
    expect(ErrorNotifier).to receive(:notify)

    expect(lock.renew).to eq(false)
  end

  it "does not release a successor's lock" do
    first = described_class.acquire(seller_id)
    $redis.del(RedisKey.workflow_seller_fanout_lock(seller_id))
    successor = described_class.acquire(seller_id)

    first.release

    expect($redis.get(RedisKey.workflow_seller_fanout_lock(seller_id))).to be_present
    successor.release
  end
end
