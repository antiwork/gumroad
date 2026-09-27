# frozen_string_literal: true

# Prepended to every prod console query. KEYS and FLUSH* walk or wipe the whole
# keyspace on the shared primary, and Redis is single-threaded: one KEYS over
# millions of keys blocks every puma and Sidekiq client until it returns. Use
# SCAN (`$redis.scan_each(match:, count:)`) with a bounded loop instead.
module GumclawConsoleRedisGuard
  BLOCKED = %w[keys flushall flushdb].freeze

  def self.check!(command)
    name = command.first.to_s.downcase
    return unless BLOCKED.include?(name)
    raise ArgumentError, "prod console refuses Redis #{name.upcase}: it blocks the shared server. Use SCAN (scan_each) instead."
  end

  def call(command, config)
    GumclawConsoleRedisGuard.check!(command)
    super
  end

  def call_pipelined(commands, config)
    commands.each { |command| GumclawConsoleRedisGuard.check!(command) }
    super
  end
end
require "redis_client"
RedisClient.register(GumclawConsoleRedisGuard)
