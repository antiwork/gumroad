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

  describe ".tool_bucket" do
    it "keeps a known tool and outcome, and folds anything else into other" do
      expect(described_class.tool_bucket("publish_product", "ok")).to eq("publish_product|ok")
      expect(described_class.tool_bucket("publish_product", "scope")).to eq("publish_product|scope")
      expect(described_class.tool_bucket("wire_payouts_to_attacker", "ok")).to eq("other|ok")
      expect(described_class.tool_bucket("publish_product", "exploded")).to eq("publish_product|other")
    end

    it "names every tool the server advertises, so a new tool cannot go uncounted" do
      advertised = Mcp::Server.new(user: create(:user), token: nil, connector: "muse").send(:tools).map { |tool| tool[:name] }

      expect(described_class::TOOLS).to match_array(advertised)
    end
  end

  describe ".record_tools" do
    it "ignores a connector that is not one of the endpoint's" do
      described_class.record_tools("elsewhere", { "get_account|ok" => 1 })

      expect($redis.exists?(RedisKey.mcp_tool_calls(Date.current))).to be(false)
    end

    it "keeps the day's expiry on the tool counter" do
      described_class.record_tools("muse", { "get_account|ok" => 1 })

      expect($redis.ttl(RedisKey.mcp_tool_calls(Date.current))).to be_within(5).of(described_class::RETENTION.to_i)
    end
  end

  describe ".tool_mix" do
    it "groups the counters by connector, tool and outcome" do
      described_class.record_tools("claude", { "create_draft_product|ok" => 2, "publish_product|scope" => 1 })
      described_class.record_tools("muse", { "get_account|error" => 1 })

      expect(described_class.tool_mix).to eq(
        "claude" => { "create_draft_product" => { "ok" => 2 }, "publish_product" => { "scope" => 1 } },
        "muse" => { "get_account" => { "error" => 1 } }
      )
    end

    it "counts the same tool once per outcome" do
      described_class.record_tools("claude", { "publish_product|ok" => 1 })
      described_class.record_tools("claude", { "publish_product|error" => 1 })

      expect(described_class.tool_mix).to eq("claude" => { "publish_product" => { "ok" => 1, "error" => 1 } })
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
