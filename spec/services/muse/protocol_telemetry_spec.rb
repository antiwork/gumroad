# frozen_string_literal: true

require "spec_helper"

describe Muse::ProtocolTelemetry do
  describe ".record" do
    it "expires a day's counters" do
      described_class.record(connector: "muse", declared_version: nil, method: "tools/list")

      expect($redis.ttl(RedisKey.mcp_protocol_requests(Date.current))).to be_within(5).of(described_class::RETENTION.to_i)
    end

    it "ignores a connector that is not one of the endpoint's" do
      described_class.record(connector: "elsewhere", declared_version: nil, method: "tools/list")

      expect($redis.exists?(RedisKey.mcp_protocol_requests(Date.current))).to be(false)
    end

    it "survives a Redis failure" do
      allow($redis).to receive(:hincrby).and_raise(Redis::CannotConnectError, "no connection")

      expect { described_class.record(connector: "muse", declared_version: nil, method: "tools/list") }.not_to raise_error
    end
  end

  describe ".mix" do
    it "groups the counters by connector, declared version and method" do
      described_class.record(connector: "claude", declared_version: "2026-07-28", method: "tools/call")
      described_class.record(connector: "claude", declared_version: "2026-07-28", method: "tools/call")
      described_class.record(connector: "muse", declared_version: nil, method: "initialize")

      expect(described_class.mix).to eq(
        "claude" => { "2026-07-28" => { "tools/call" => 2 } },
        "muse" => { "undeclared" => { "initialize" => 1 } }
      )
    end
  end
end
