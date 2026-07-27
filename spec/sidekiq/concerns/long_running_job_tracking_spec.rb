# frozen_string_literal: true

describe LongRunningJobTracking do
  let(:key) { RedisKey.long_running_jobs_in_flight }

  before { $redis.del(key) }
  after  { $redis.del(key) }

  # A stand-in for a real long-running report job: it records what the tracking set looked
  # like while its work was running, so we can assert on the in-flight state as well as the
  # cleaned-up state afterwards.
  let(:job_class) do
    Class.new do
      include Sidekiq::Job
      include LongRunningJobTracking

      class << self
        attr_accessor :entries_while_running, :received_args, :raise_error
      end

      def self.name = "SpecLongRunningJob"

      def perform(*args)
        self.class.received_args = args
        self.class.entries_while_running = $redis.zrange(RedisKey.long_running_jobs_in_flight, 0, -1)
        raise "boom" if self.class.raise_error
        "return value"
      end
    end
  end

  it "registers exactly one entry while the job runs and removes it afterwards" do
    job_class.new.perform

    expect(job_class.entries_while_running.size).to eq(1)
    expect(job_class.entries_while_running.first).to include("SpecLongRunningJob")
    expect($redis.zcard(key)).to eq(0)
  end

  it "passes the job's arguments and return value through untouched" do
    # The wrapper must be in the chain for this to mean anything — otherwise the stand-in's
    # own perform would satisfy the assertions with the feature reverted.
    expect(job_class.ancestors).to include(LongRunningJobTracking::PerformWrapper)

    expect(job_class.new.perform(4, 2026)).to eq("return value")
    expect(job_class.received_args).to eq([4, 2026])
    expect(job_class.entries_while_running.size).to eq(1)
  end

  it "removes its entry when the job raises, so a failure can't freeze deploys" do
    job_class.raise_error = true

    expect { job_class.new.perform }.to raise_error("boom")
    expect($redis.zcard(key)).to eq(0)
  end

  it "leaves a concurrently running job's entry alone" do
    $redis.zadd(key, Time.current.to_i, "sibling-job-token")

    job_class.new.perform

    expect(job_class.entries_while_running.size).to eq(2)
    expect($redis.zscore(key, "sibling-job-token")).to be_present
  end

  it "scores its entry with the start time and expires the key, so a crashed job can only hold deploys for the TTL" do
    allow($redis).to receive(:zrem) # simulate a job that dies before cleaning up

    started_at = Time.current.to_i
    job_class.new.perform

    # The score is the crash-safety mechanism the healthcheck relies on: readers prune by
    # score (zremrangebyscore), and the key-level expiry is only a backstop, since any later
    # registration refreshes it.
    token = $redis.zrange(key, 0, -1).first
    expect($redis.zscore(key, token)).to be_between(started_at, Time.current.to_i)
    expect($redis.ttl(key)).to be_between(1, LongRunningJobTracking::IN_FLIGHT_ENTRY_TTL.to_i)
  end

  it "stops blocking deploys once its entry is older than the TTL" do
    allow($redis).to receive(:zrem) # simulate a job that dies before cleaning up

    job_class.new.perform
    expect(
      DeployBlockingJobTracking.any_in_flight?(key, LongRunningJobTracking::IN_FLIGHT_ENTRY_TTL)
    ).to be(true)

    travel_to (LongRunningJobTracking::IN_FLIGHT_ENTRY_TTL + 1.minute).from_now do
      expect(
        DeployBlockingJobTracking.any_in_flight?(key, LongRunningJobTracking::IN_FLIGHT_ENTRY_TTL)
      ).to be(false)
    end
  end
end
