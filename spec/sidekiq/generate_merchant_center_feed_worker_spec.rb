# frozen_string_literal: true

require "spec_helper"

describe GenerateMerchantCenterFeedWorker do
  it "runs the feed with the given product cap" do
    run = instance_double(MerchantCenterFeedRun)
    expect(MerchantCenterFeedRun).to receive(:new).and_return(run)
    expect(run).to receive(:call).with(max_products: 500)

    described_class.new.perform(500)
  end

  it "defaults to the service's safety cap" do
    run = instance_double(MerchantCenterFeedRun)
    expect(MerchantCenterFeedRun).to receive(:new).and_return(run)
    expect(run).to receive(:call).with(max_products: MerchantCenterFeedService::DEFAULT_MAX_PRODUCTS)

    described_class.new.perform
  end

  context "when another run holds the lock" do
    before { $redis.set(RedisKey.merchant_center_feed_lock, "someone-else", ex: 60) }

    it "tries again after a delay with the same cap, without failing the job" do
      expect { described_class.new.perform(500) }.not_to raise_error

      expect(described_class.jobs.size).to eq 1
      expect(described_class.jobs.first["args"]).to eq [500, 2]
      expect(described_class.jobs.first["at"]).to be_within(5).of(described_class::LOCK_RETRY_DELAY.from_now.to_f)
    end

    it "keeps trying for longer than the run lock lives" do
      expect(described_class::LOCK_RETRY_DELAY * (described_class::LOCK_MAX_ATTEMPTS - 1))
        .to be > MerchantCenterFeedRun::LOCK_TTL.seconds
    end

    it "fails the job after the last attempt" do
      expect { described_class.new.perform(500, described_class::LOCK_MAX_ATTEMPTS) }
        .to raise_error(MerchantCenterFeedRun::GenerationInProgress)

      expect(described_class.jobs).to be_empty
    end
  end
end
