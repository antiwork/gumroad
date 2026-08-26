# frozen_string_literal: true

require "spec_helper"

describe SellerLargeBlastQuota, :freeze_time do
  let(:seller_id) { 1888878 }
  let(:first_blast) { 11 }
  let(:second_blast) { 22 }

  after do
    $redis.del(RedisKey.seller_large_blast_quota(seller_id, Date.current))
    $redis.del(RedisKey.seller_large_blast_threshold)
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

  it "opens a new slot the next day" do
    expect(described_class.allow?(seller_id:, blast_id: first_blast, recipient_count: described_class::DEFAULT_THRESHOLD)).to eq(true)

    travel 1.day
    expect(described_class.allow?(seller_id:, blast_id: second_blast, recipient_count: described_class::DEFAULT_THRESHOLD)).to eq(true)
  end
end
