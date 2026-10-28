# frozen_string_literal: true

require "spec_helper"

describe Mcp::ProtocolTelemetry do
  describe ".bucket" do
    it "keeps an exact known revision and method" do
      expect(described_class.bucket("2026-07-28", "server/discover")).to eq("2026-07-28|server/discover")
      expect(described_class.bucket("2025-06-18", "tools/call")).to eq("2025-06-18|tools/call")
    end

    it "counts an absent declaration apart from one it does not know" do
      expect(described_class.bucket(nil, "tools/list")).to eq("undeclared|tools/list")
      ["2099-01-01", " 2026-07-28", "2026-07-28 ", "2026-7-28", 20260728].each do |declared|
        expect(described_class.bucket(declared, "tools/list")).to eq("other|tools/list")
      end
    end

    it "buckets any method the endpoint does not dispatch" do
      ["prompts/list", "tools/call/jane_doe-5551234567", nil, 42].each do |method|
        expect(described_class.bucket(nil, method)).to eq("undeclared|other")
      end
    end
  end

  describe ".record" do
    it "ignores a connector that is not one of the endpoint's" do
      described_class.record("elsewhere", { "undeclared|tools/list" => 1 })

      expect($redis.exists?(RedisKey.mcp_protocol_requests(Date.current))).to be(false)
    end
  end

  describe ".mix" do
    it "groups the counters by connector, declared version and method" do
      described_class.record("claude", { "2026-07-28|tools/call" => 2 })
      described_class.record("muse", { "undeclared|initialize" => 1 })

      expect(described_class.mix).to eq(
        "claude" => { "2026-07-28" => { "tools/call" => 2 } },
        "muse" => { "undeclared" => { "initialize" => 1 } }
      )
    end
  end

  describe "a Redis that accepts connections and never answers" do
    it "costs a batch request one short wait and no reconnect" do
      server = TCPServer.new("127.0.0.1", 0)
      connections = Queue.new
      acceptor = Thread.new { loop { connections << server.accept } }
      endpoint = "127.0.0.1:#{server.addr[1]}"
      original_host = ENV["REDIS_HOST"]
      original_redis = $redis
      ENV["REDIS_HOST"] = endpoint
      $redis = Redis.new(url: "redis://#{endpoint}")
      batch = Array.new(3) { |id| { "jsonrpc" => "2.0", "id" => id, "method" => "tools/list" } }

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = Mcp::Server.new(user: create(:user), token: nil, connector: "muse").handle(batch)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(result.map { _1[:id] }).to eq([0, 1, 2])
      expect(connections.size).to eq(1)
      expect(elapsed).to be < 1
    ensure
      ENV["REDIS_HOST"] = original_host
      $redis = original_redis
      acceptor&.kill
      connections&.size&.times { connections.pop.close }
      server&.close
    end
  end
end
