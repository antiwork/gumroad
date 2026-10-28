# frozen_string_literal: true

module Mcp
  # Counts who calls the MCP endpoint on which revision: one counter per connector path, declared
  # protocol version (or none) and method. Kept in Redis so a client that has moved is visible from
  # `Mcp::ProtocolTelemetry.mix` without a table or a metrics vendor.
  #
  # Every bucket comes from a closed list, so a day holds at most CONNECTORS × VERSIONS × METHODS
  # fields and no client-supplied string is ever stored.
  module ProtocolTelemetry
    CONNECTORS = %w[muse claude chatgpt].freeze
    # Every published revision, so a client declaring one we do not serve is still named.
    VERSIONS = (Server::SUPPORTED_VERSIONS + %w[2024-11-05 2025-06-18 2025-11-25]).uniq.freeze
    # The methods this endpoint dispatches.
    METHODS = %w[initialize notifications/cancelled notifications/initialized ping server/discover tools/call tools/list].freeze
    UNDECLARED = "undeclared"
    OTHER = "other"
    RETENTION = 90.days
    SEPARATOR = "|"
    # Seconds. A stalled Redis costs a connector request at most a few of these, once per request.
    TIMEOUT = 0.25
    # Counts and retention land in one atomic step, so a day is never left without its expiry.
    # ARGV: retention seconds, then field/count pairs.
    INCREMENT_SCRIPT = <<~LUA
      for i = 2, #ARGV, 2 do
        redis.call("HINCRBY", KEYS[1], ARGV[i], ARGV[i + 1])
      end
      return redis.call("EXPIRE", KEYS[1], ARGV[1])
    LUA

    class << self
      # The version|method part of a field. Bucketed per message, so a request's tally stays
      # bounded however large its batch.
      def bucket(declared_version, method)
        [version_bucket(declared_version), method_bucket(method)].join(SEPARATOR)
      end

      # One write per HTTP request. Best-effort: telemetry is never the reason a connector request fails.
      def record(connector, counts)
        return if counts.empty? || !CONNECTORS.include?(connector.to_s)

        pairs = counts.flat_map { |bucket, count| ["#{connector}#{SEPARATOR}#{bucket}", count] }
        redis.eval(INCREMENT_SCRIPT, keys: [RedisKey.mcp_protocol_requests(Date.current)], argv: [RETENTION.to_i, *pairs])
      rescue StandardError => e
        Rails.logger.warn("mcp_protocol_telemetry_failed #{e.class}")
      end

      # connector => declared version => JSON-RPC method => messages
      def mix(date: Date.current)
        redis.hgetall(RedisKey.mcp_protocol_requests(date)).each_with_object({}) do |(field, count), mix|
          connector, version, method = field.split(SEPARATOR, 3)
          mix[connector] ||= {}
          mix[connector][version] ||= {}
          mix[connector][version][method] = count.to_i
        end
      end

      private
        # Its own client so the short timeout applies to telemetry alone. No reconnect attempts:
        # a retried EVAL whose reply was lost would count twice. Rebuilt when REDIS_HOST changes,
        # which test isolation does per forked command.
        def redis
          host, client = @redis
          return client if host == ENV["REDIS_HOST"]

          client = Redis.new(url: "redis://#{ENV["REDIS_HOST"]}", timeout: TIMEOUT, reconnect_attempts: 0)
          @redis = [ENV["REDIS_HOST"], client]
          client
        end

        # Exact match only: a padded or unknown declaration is not one of these revisions.
        def version_bucket(value)
          return UNDECLARED if value.nil?

          VERSIONS.include?(value) ? value : OTHER
        end

        def method_bucket(value)
          METHODS.include?(value) ? value : OTHER
        end
    end
  end
end
