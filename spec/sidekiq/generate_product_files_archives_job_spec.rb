# frozen_string_literal: true

require "spec_helper"

describe GenerateProductFilesArchivesJob do
  let(:product) { create(:product) }

  it "rebuilds the product's archives under the row lock" do
    expect(Link).to receive(:find_by).with(id: product.id).and_return(product)
    expect(product).to receive(:with_lock).and_yield
    expect(product).to receive(:generate_product_files_archives!)

    described_class.new.perform(product.id)
  end

  it "skips deleted and missing products" do
    product.mark_deleted!
    expect_any_instance_of(Link).not_to receive(:generate_product_files_archives!)

    described_class.new.perform(product.id)
    described_class.new.perform(-1)
  end

  # Same pairing as GenerateSslCertificate::RENEWAL_LOCK_OPTIONS: until_executing so a queued
  # rebuild absorbs later enqueues, a positive TTL so a lock stranded by a killed enqueue
  # cannot mute every later enqueue forever. The TTL must stay above the buyer-poll cooldown
  # in UrlRedirect so a stranded lock, not the cooldown, is the recovery bound.
  it "pairs until_executing with a positive bounded lock ttl" do
    options = described_class.sidekiq_options

    expect(options["lock"].to_s).to eq("until_executing")
    expect(options["on_conflict"].to_s).to eq("log")
    expect(options["lock_ttl"]).to eq(described_class::LOCK_TTL.to_i)
    expect(options["lock_ttl"]).to be_positive
    expect(described_class::LOCK_TTL).to be > UrlRedirect::FOLDER_ARCHIVE_REBUILD_COOLDOWN
  end

  # The initializer disables SidekiqUniqueJobs in test, so these run the installed client and
  # server middleware and their Lua scripts against the test Redis for real. Sidekiq::Testing
  # keeps its own server chain, which does not carry the unique server middleware, so a plain
  # drain would never release an until_executing lock; the chain is extended for the example.
  context "with the unique lock enabled" do
    around do |example|
      SidekiqUniqueJobs.use_config(enabled: true) do
        Sidekiq::Testing.server_middleware { |chain| chain.add SidekiqUniqueJobs::Middleware::Server }
        example.run
      ensure
        Sidekiq::Testing.server_middleware { |chain| chain.remove SidekiqUniqueJobs::Middleware::Server }
      end
    end

    let(:lock_ttl_ms) { described_class::LOCK_TTL.in_milliseconds }

    def lock_key_for(job)
      SidekiqUniqueJobs::Key.new(job["lock_digest"])
    end

    def pttl(key)
      Sidekiq.redis { |conn| conn.pttl(key) }
    end

    def lock_held?(key)
      Sidekiq.redis { |conn| conn.exists(key.digest, key.locked) }.positive?
    end

    # Pro's reliable push holds a job in process memory when Redis refuses the push, but the
    # unique lock was already written to Redis before that push. Dropping the job from the
    # fake queue while leaving the lock keys alone is the state a process death leaves behind.
    # This is the lock state only, not the Pro client.
    def lose_pushed_job_keeping_lock!(job)
      Sidekiq::Queues.delete_for(job["jid"], job["queue"], described_class.name)
    end

    # Redis expiry is wall-clock, so the TTL elapsing is stood in for by re-issuing the PEXPIRE
    # lock.lua set at enqueue with a 1ms deadline, then observing the keys gone.
    def expire_lock!(key)
      Sidekiq.redis do |conn|
        [key.digest, key.locked, key.info].each { |redis_key| conn.pexpire(redis_key, 1) }
      end
      Timeout.timeout(2) { sleep 0.005 while lock_held?(key) }
    end

    it "stamps the lock with the declared ttl and expires a lock stranded by a lost push" do
      expect(described_class.perform_async(product.id)).to be_present
      job = described_class.jobs.last
      key = lock_key_for(job)

      expect(job["lock_ttl"]).to eq(described_class::LOCK_TTL.to_i)
      [key.digest, key.locked].each do |redis_key|
        expect(pttl(redis_key)).to be_between((described_class::LOCK_TTL - 1.minute).in_milliseconds, lock_ttl_ms)
      end

      lose_pushed_job_keeping_lock!(job)
      expect(described_class.jobs).to be_empty
      expect(lock_held?(key)).to be(true)

      # The stranded state: every later push dedupes onto a job that no longer exists.
      3.times { expect(described_class.perform_async(product.id)).to be_nil }
      expect(described_class.jobs).to be_empty

      expire_lock!(key)

      expect(described_class.perform_async(product.id)).to be_present
      expect(described_class.jobs.size).to eq(1)
      expect(described_class).to have_enqueued_sidekiq_job(product.id)
    end

    it "dedupes pushes while queued and releases the lock when execution starts" do
      expect(described_class.perform_async(product.id)).to be_present
      key = lock_key_for(described_class.jobs.last)
      expect(described_class.perform_async(product.id)).to be_nil
      expect(described_class.jobs.size).to eq(1)

      expect_any_instance_of(Link).to receive(:generate_product_files_archives!)
      described_class.drain

      # Released at execution start, not at completion: a push after the job has begun is a new
      # job, so "one enqueue per ttl" is not a bound this lock provides.
      expect(lock_held?(key)).to be(false)
      expect(described_class.perform_async(product.id)).to be_present
    end

    it "re-locks on a failed execution so retries stay deduplicated, and frees the digest when retries die" do
      expect(described_class.perform_async(product.id)).to be_present
      job = described_class.jobs.last
      key = lock_key_for(job)
      allow_any_instance_of(Link).to receive(:generate_product_files_archives!).and_raise("rebuild failed")

      expect { described_class.drain }.to raise_error("rebuild failed")

      expect(lock_held?(key)).to be(true)
      expect(pttl(key.locked)).to be_between(1, lock_ttl_ms)
      expect(described_class.perform_async(product.id)).to be_nil

      SidekiqUniqueJobs::Server.death_handler.call(job, RuntimeError.new("rebuild failed"))

      expect(lock_held?(key)).to be(false)
      expect(described_class.perform_async(product.id)).to be_present
    end

    # The known cost of the bound: a TTL shorter than the low-queue backlog admits one
    # duplicate per TTL, which the product row lock in perform serializes behind the original.
    it "admits one duplicate when the ttl elapses under a still-queued job" do
      expect(described_class.perform_async(product.id)).to be_present
      key = lock_key_for(described_class.jobs.last)

      expire_lock!(key)

      expect(described_class.perform_async(product.id)).to be_present
      expect(described_class.jobs.size).to eq(2)
      expect(described_class.perform_async(product.id)).to be_nil
      expect(described_class.jobs.size).to eq(2)
    end
  end
end
