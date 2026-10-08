# frozen_string_literal: true

require "zlib"

# MINITEST_SHARD=<index>/<total> runs only this shard's tests. Every shard loads
# every file and keeps the tests whose name hashes to its index, so the few large
# files spread across all shards instead of setting the slowest one's length.
module TestShard
  def self.parse(value)
    match = /\A(\d+)\/(\d+)\z/.match(value.to_s)
    raise ArgumentError, "MINITEST_SHARD must be <index>/<total>, got #{value.inspect}" unless match

    index, total = match.captures.map(&:to_i)
    raise ArgumentError, "MINITEST_SHARD index must be below total, got #{value.inspect}" unless index < total

    [index, total]
  end

  def self.current
    @current ||= ENV["MINITEST_SHARD"].to_s.empty? ? :none : parse(ENV["MINITEST_SHARD"])
    @current == :none ? nil : @current
  end

  def self.member?(test_id, index, total)
    Zlib.crc32(test_id) % total == index
  end

  module RunnableMethods
    def runnable_methods
      index, total = TestShard.current
      return super unless total

      super.select { |method_name| TestShard.member?("#{name}##{method_name}", index, total) }
    end
  end
end

Minitest::Test.singleton_class.prepend(TestShard::RunnableMethods)
