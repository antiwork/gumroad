# frozen_string_literal: true

require "spec_helper"

describe ReplicaLagWatcher do
  after do
    Thread.current["ReplicaLagWatcher.connections"] = nil
    Thread.current["ReplicaLagWatcher.last_checked_at"] = nil
  end

  describe ".watch" do
    it "sleeps if a replica is lagging" do
      stub_const("REPLICAS_HOSTS", [double])
      expect(described_class).to receive(:connect_to_replicas)
      expect(described_class).to receive(:lagging?).with(any_args).and_return(true, true, false)
      expect(described_class).to receive(:sleep).with(1).twice

      described_class.watch(silence: true)
    end

    it "does nothing if there are no replicas" do
      stub_const("REPLICAS_HOSTS", [])
      expect(described_class).not_to receive(:lagging?)

      described_class.watch
      expect(described_class.last_checked_at).to eq(nil)
    end
  end

  describe ".lagging?" do
    before do
      @options = { check_every: 1.second, max_lag_allowed: 1.second, silence: true }
      allow(described_class).to receive(:check_for_lag?).with(1.second).and_return(true)
      described_class.connections = []
    end

    def set_connections
      described_class.connections = [double(query_options: { host: "replica.host" })]
      query_response = [{ "Seconds_Behind_Master" => @seconds_behind_master }]
      expect(described_class.connections.first).to receive(:query).with("SHOW SLAVE STATUS").and_return(query_response)
    end

    it "sets last_checked_at" do
      described_class.lagging?(@options)
      expect(described_class.last_checked_at.is_a?(Float)).to eq(true)
    end

    it "returns true if one of the replica connections is lagging" do
      @seconds_behind_master = 2
      set_connections
      expect(described_class.lagging?(@options)).to eq(true)
    end

    it "returns false if no connections are lagging" do
      @seconds_behind_master = 0
      set_connections
      expect(described_class.lagging?(@options)).to eq(false)
    end

    it "raises an error if the lag can't be determined" do
      @seconds_behind_master = nil
      set_connections
      expect do
        described_class.lagging?(@options)
      end.to raise_error(/lag = null/)
    end

    it "returns nil if it doesn't need to check for lag" do
      expect(described_class).to receive(:check_for_lag?).with(1).and_return(false)
      expect(described_class.lagging?(@options)).to eq(nil)
    end
  end

  describe ".check_for_lag?" do
    it "returns true if it was never checked before" do
      expect(described_class.check_for_lag?(1)).to eq(true)
    end

    it "returns true/false whether it was checked more or less than the allowed time" do
      check_every = 1
      # Test relies on the reasonable assumption that it takes less than a second the two following lines
      described_class.last_checked_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(described_class.check_for_lag?(check_every)).to eq(false)

      # One second later we should check for lag again
      sleep 1
      expect(described_class.check_for_lag?(check_every)).to eq(true)
    end
  end

  describe ".connect_to_replicas" do
    it "does not set new connections if some exist already" do
      described_class.connections = [double]
      expect(described_class).not_to receive(:connections=)
      described_class.connect_to_replicas
    end

    it "sets connections if they weren't set before" do
      stub_const("REPLICAS_HOSTS", ["web-replica-1.aaaaaa.us-east-1.rds.amazonaws.com"])
      connection_double = double
      expect(Mysql2::Client).to receive(:new).with(
        host: "web-replica-1.aaaaaa.us-east-1.rds.amazonaws.com",
        username: ActiveRecord::Base.connection_db_config.configuration_hash[:username],
        password: ActiveRecord::Base.connection_db_config.configuration_hash[:password],
        database: ActiveRecord::Base.connection_db_config.configuration_hash[:database],
      ).and_return(connection_double)

      described_class.connect_to_replicas
      expect(described_class.connections).to eq([connection_double])
    end
  end
end
