# frozen_string_literal: true

require "spec_helper"

describe MerchantCenterFeedRun do
  let(:run) { described_class.new }
  let(:feed_glob) { Rails.public_path.join("sitemap/merchant-center/feed*.xml") }

  def create_eligible_product
    product = create(:product, :recommendable, price_cents: 999)
    create(:asset_preview, link: product)
    product.reload
  end

  def published
    Dir[feed_glob].map { |path| File.basename(path) }.sort
  end

  before { FileUtils.rm_f(Dir[feed_glob]) }
  after do
    FileUtils.rm_f(Dir[feed_glob])
    Feature.deactivate(described_class::KILL_SWITCH)
  end

  context "with no shard configured" do
    it "publishes the legacy feed and nothing else" do
      create_eligible_product

      expect(run.call).to eq :completed

      expect(published).to eq ["feed.xml"]
    end

    it "does not touch the shard code path" do
      create_eligible_product
      expect_any_instance_of(MerchantCenterFeedService).not_to receive(:generate_shard)

      run.call
    end

    it "passes max_products to the legacy feed" do
      2.times { create_eligible_product }

      run.call(max_products: 1)

      expect(Nokogiri::XML(File.read(Rails.public_path.join("sitemap/merchant-center/feed.xml"))).xpath("//item").size).to eq 1
    end
  end

  context "with a shard stage configured" do
    before do
      3.times { create_eligible_product }
      stub_const("MerchantCenterFeedService::SHARD_WIDTH", Link.maximum(:id) - 1)
    end

    it "publishes the legacy feed and shards 0 through the stage" do
      $redis.set(RedisKey.merchant_center_feed_max_shard, 1)

      run.call

      expect(published).to eq ["feed-00.xml", "feed-01.xml", "feed.xml"]
    end

    it "does not publish shards past the last one that can hold a product" do
      $redis.set(RedisKey.merchant_center_feed_max_shard, 50)

      run.call

      expect(published).to eq ["feed-00.xml", "feed-01.xml", "feed.xml"]
    end
  end

  describe "kill switch" do
    before { create_eligible_product }

    it "publishes nothing and takes no lock when engaged before the run" do
      Feature.activate(described_class::KILL_SWITCH)

      expect(run.call).to eq :stopped

      expect(published).to be_empty
      expect($redis.get(RedisKey.merchant_center_feed_lock)).to be_nil
    end

    it "stops mid-file without publishing a partial feed and releases the lock" do
      allow_any_instance_of(MerchantCenterFeedService).to receive(:eligible?).and_wrap_original do |original, product|
        original.call(product).tap { Feature.activate(described_class::KILL_SWITCH) }
      end

      expect(run.call).to eq :stopped

      expect(published).to be_empty
      expect($redis.get(RedisKey.merchant_center_feed_lock)).to be_nil
    end

    it "stops between shards" do
      stub_const("MerchantCenterFeedService::SHARD_WIDTH", Link.maximum(:id))
      $redis.set(RedisKey.merchant_center_feed_max_shard, 1)
      allow_any_instance_of(MerchantCenterFeedService).to receive(:generate).and_wrap_original do |original, **options|
        original.call(**options).tap { Feature.activate(described_class::KILL_SWITCH) }
      end

      expect(run.call).to eq :stopped

      expect(published).to eq ["feed.xml"]
    end
  end

  describe "run lock" do
    before { create_eligible_product }

    it "refuses to run beside another run and leaves its lock alone" do
      $redis.set(RedisKey.merchant_center_feed_lock, "someone-else", ex: 60)

      expect { run.call }.to raise_error(described_class::GenerationInProgress)

      expect($redis.get(RedisKey.merchant_center_feed_lock)).to eq "someone-else"
      expect(published).to be_empty
    end

    it "releases the lock after a run" do
      run.call

      expect($redis.get(RedisKey.merchant_center_feed_lock)).to be_nil
    end

    it "releases the lock after a failure" do
      allow_any_instance_of(MerchantCenterFeedService).to receive(:generate).and_raise("boom")

      expect { run.call }.to raise_error("boom")

      expect($redis.get(RedisKey.merchant_center_feed_lock)).to be_nil
    end

    it "renews the lock after every batch" do
      stub_const("MerchantCenterFeedService::BATCH_SIZE", 1)
      create_eligible_product
      ttls = []
      allow_any_instance_of(MerchantCenterFeedService).to receive(:eligible?).and_wrap_original do |original, product|
        ttls << $redis.ttl(RedisKey.merchant_center_feed_lock)
        $redis.expire(RedisKey.merchant_center_feed_lock, 10)
        original.call(product)
      end

      run.call

      # Each row shortens the lock to 10 seconds; only a renewal after the batch restores it.
      expect(ttls.last).to be > described_class::LOCK_TTL - 5
    end

    it "stops without publishing when the lock is lost mid-run" do
      allow_any_instance_of(MerchantCenterFeedService).to receive(:eligible?).and_wrap_original do |original, product|
        $redis.del(RedisKey.merchant_center_feed_lock)
        original.call(product)
      end

      expect { run.call }.to raise_error(described_class::LockLost)

      expect(published).to be_empty
    end

    it "stops without marking the file finished when the lock is lost during the upload" do
      allow_any_instance_of(MerchantCenterFeedService).to receive(:upload).and_wrap_original do |original, *args|
        $redis.del(RedisKey.merchant_center_feed_lock)
        original.call(*args)
      end

      expect { run.call }.to raise_error(described_class::LockLost)

      expect($redis.hexists(RedisKey.merchant_center_feed_progress, described_class::LEGACY_UNIT)).to be false
    end

    it "renews the lock while a file uploads" do
      ttls = []
      allow_any_instance_of(MerchantCenterFeedService).to receive(:upload).and_wrap_original do |original, *args|
        $redis.expire(RedisKey.merchant_center_feed_lock, 10)
        original.call(*args)
      end
      stub_const("MerchantCenterFeedService::UPLOAD_CHECK_IN_INTERVAL", 0)
      allow_any_instance_of(MerchantCenterFeedService).to receive(:upload_to_s3?).and_return(true)
      allow_any_instance_of(MerchantCenterFeedService).to receive(:s3_client).and_return(instance_double(Aws::S3::Client))
      allow_any_instance_of(Aws::S3::Object).to receive(:upload_file) do |_object, _path, options|
        options[:progress_callback].call([1], [2])
        ttls << $redis.ttl(RedisKey.merchant_center_feed_lock)
      end

      run.call

      expect(ttls.first).to be > described_class::LOCK_TTL - 5
    end

    it "does not delete a lock another run took over" do
      allow_any_instance_of(MerchantCenterFeedService).to receive(:eligible?).and_wrap_original do |original, product|
        $redis.set(RedisKey.merchant_center_feed_lock, "someone-else")
        original.call(product)
      end

      expect { run.call }.to raise_error(described_class::LockLost)

      expect($redis.get(RedisKey.merchant_center_feed_lock)).to eq "someone-else"
    end
  end

  describe "an oversized shard" do
    before do
      2.times { create_eligible_product }
      stub_const("MerchantCenterFeedService::SHARD_WIDTH", Link.maximum(:id) - 1)
      $redis.set(RedisKey.merchant_center_feed_max_shard, 1)
    end

    it "is reported once, keeps its previous file, and does not hold back the other shards" do
      path = Rails.public_path.join(MerchantCenterFeedService.shard_key(0))
      FileUtils.mkdir_p(path.dirname)
      File.write(path, "yesterday")
      allow_any_instance_of(MerchantCenterFeedService).to receive(:generate_shard).and_wrap_original do |original, index|
        raise MerchantCenterFeedService::ShardTooLarge, "too big" if index == 0

        original.call(index)
      end
      expect(ErrorNotifier).to receive(:notify).with(kind_of(MerchantCenterFeedService::ShardTooLarge), unit: "shard:0").once

      expect(run.call).to eq :completed

      expect(File.read(path)).to eq "yesterday"
      expect(published).to include("feed-01.xml")
    end
  end

  describe "resuming" do
    before do
      3.times { create_eligible_product }
      stub_const("MerchantCenterFeedService::SHARD_WIDTH", Link.maximum(:id) - 1)
      $redis.set(RedisKey.merchant_center_feed_max_shard, 1)
    end

    it "skips the files a failed run finished and redoes the one that failed" do
      generated = []
      allow_any_instance_of(MerchantCenterFeedService).to receive(:generate).and_wrap_original do |original, **options|
        generated << :legacy
        original.call(**options)
      end
      allow_any_instance_of(MerchantCenterFeedService).to receive(:generate_shard).and_wrap_original do |original, index|
        generated << index
        raise "S3 down" if index == 1 && generated.count(1) == 1

        original.call(index)
      end

      expect { run.call }.to raise_error("S3 down")
      expect(generated).to eq [:legacy, 0, 1]

      expect(run.call).to eq :completed
      expect(generated).to eq [:legacy, 0, 1, 1]
      expect(published).to eq ["feed-00.xml", "feed-01.xml", "feed.xml"]
    end

    it "starts over after a completed run" do
      run.call
      generated = []
      allow_any_instance_of(MerchantCenterFeedService).to receive(:generate_shard).and_wrap_original do |original, index|
        generated << index
        original.call(index)
      end

      run.call

      expect(generated).to eq [0, 1]
      expect($redis.exists?(RedisKey.merchant_center_feed_progress)).to be false
    end
  end
end
