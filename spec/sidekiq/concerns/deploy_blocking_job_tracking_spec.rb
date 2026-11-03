# frozen_string_literal: true

require "spec_helper"

describe DeployBlockingJobTracking do
  let(:key) { RedisKey.long_running_jobs_in_flight }
  let(:ttl) { LongRunningJobTracking::IN_FLIGHT_ENTRY_TTL }
  let(:old_enough) { (DeployBlockingJobTracking::DEAD_PROCESS_GRACE + 1.minute).ago.to_i }

  before { $redis.del(key) }
  after  { $redis.del(key) }

  def token_for(identity)
    ["SomeReportJob", identity, SecureRandom.uuid].join(DeployBlockingJobTracking::TOKEN_SEPARATOR)
  end

  describe ".any_in_flight?" do
    it "drops an entry whose Sidekiq process no longer heartbeats (OOM-killed worker)" do
      dead = token_for("sidekiq_worker-abc:7:deadbeef0001")
      $redis.zadd(key, old_enough, dead)
      allow(Sidekiq::ProcessSet).to receive(:[]).with("sidekiq_worker-abc:7:deadbeef0001").and_return(nil)

      expect(described_class.any_in_flight?(key, ttl)).to be(false)
      expect($redis.zscore(key, dead)).to be_nil
    end

    it "keeps an entry whose Sidekiq process is alive" do
      live = token_for("sidekiq_worker-abc:7:live00000001")
      $redis.zadd(key, old_enough, live)
      allow(Sidekiq::ProcessSet).to receive(:[]).with("sidekiq_worker-abc:7:live00000001").and_return(double("process"))

      expect(described_class.any_in_flight?(key, ttl)).to be(true)
      expect($redis.zscore(key, live)).to be_present
    end

    it "keeps a dead-process entry younger than the grace period, so a heartbeat gap can't let a deploy through" do
      fresh = token_for("sidekiq_worker-abc:7:deadbeef0002")
      $redis.zadd(key, Time.current.to_i, fresh)
      expect(Sidekiq::ProcessSet).not_to receive(:[])

      expect(described_class.any_in_flight?(key, ttl)).to be(true)
    end

    it "keeps old-format entries that carry no process identity (TTL still applies)" do
      legacy = "SomeReportJob-7-#{SecureRandom.uuid}"
      $redis.zadd(key, old_enough, legacy)
      expect(Sidekiq::ProcessSet).not_to receive(:[])

      expect(described_class.any_in_flight?(key, ttl)).to be(true)
    end

    it "fails closed when Sidekiq's process registry can't be read" do
      dead = token_for("sidekiq_worker-abc:7:deadbeef0003")
      $redis.zadd(key, old_enough, dead)
      allow(Sidekiq::ProcessSet).to receive(:[]).and_raise(RedisClient::CannotConnectError)
      allow(ErrorNotifier).to receive(:notify)

      expect(described_class.any_in_flight?(key, ttl)).to be(true)
      expect($redis.zscore(key, dead)).to be_present
    end

    it "prunes only the dead entry when a live one sits alongside it" do
      dead = token_for("sidekiq_worker-abc:6:deadbeef0004")
      live = token_for("sidekiq_worker-xyz:7:live00000002")
      $redis.zadd(key, old_enough, dead)
      $redis.zadd(key, old_enough, live)
      allow(Sidekiq::ProcessSet).to receive(:[]).with("sidekiq_worker-abc:6:deadbeef0004").and_return(nil)
      allow(Sidekiq::ProcessSet).to receive(:[]).with("sidekiq_worker-xyz:7:live00000002").and_return(double("process"))

      expect(described_class.any_in_flight?(key, ttl)).to be(true)
      expect($redis.zscore(key, dead)).to be_nil
      expect($redis.zscore(key, live)).to be_present
    end
  end

  describe ".build_token" do
    it "embeds the Sidekiq process identity when running inside a Sidekiq server" do
      allow(described_class).to receive(:current_sidekiq_process_identity).and_return("sidekiq_worker-abc:7:a1b2c3d4e5f6")

      token = described_class.build_token("SomeReportJob")

      expect(described_class.process_identity_from_token(token)).to eq("sidekiq_worker-abc:7:a1b2c3d4e5f6")
    end

    it "falls back to the identity-less format outside a Sidekiq server" do
      token = described_class.build_token("SomeReportJob")

      expect(token).to start_with("SomeReportJob-#{Process.pid}-")
      expect(described_class.process_identity_from_token(token)).to be_nil
    end
  end
end
