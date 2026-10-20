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

    it "restores the retention on a later write" do
      described_class.record(connector: "muse", declared_version: nil, method: "tools/list")
      $redis.persist(RedisKey.mcp_protocol_requests(Date.current))

      described_class.record(connector: "muse", declared_version: nil, method: "tools/list")

      expect($redis.ttl(RedisKey.mcp_protocol_requests(Date.current))).to be_within(5).of(described_class::RETENTION.to_i)
    end

    it "keeps a day's field set bounded" do
      stub_const("Muse::ProtocolTelemetry::MAX_FIELDS", 2)
      described_class.record(connector: "muse", declared_version: "2025-03-26", method: "tools/list")
      described_class.record(connector: "muse", declared_version: "2025-06-18", method: "tools/list")
      described_class.record(connector: "muse", declared_version: "2026-07-28", method: "tools/list")
      described_class.record(connector: "muse", declared_version: "2025-03-26", method: "tools/list")

      expect(described_class.mix).to eq(
        "muse" => {
          "2025-03-26" => { "tools/list" => 2 },
          "2025-06-18" => { "tools/list" => 1 },
        }
      )
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
