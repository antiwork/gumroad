# frozen_string_literal: true

module Muse
  # Counts who calls the MCP endpoint on which revision: one counter per connector path, declared
  # protocol version (or none) and method. Kept in Redis so a client that has moved is visible from
  # `Muse::ProtocolTelemetry.mix` without a table or a metrics vendor.
  module ProtocolTelemetry
    CONNECTORS = %w[muse claude chatgpt].freeze
    # The methods this endpoint dispatches. A caller can send any string, so an unknown method
    # shares one bucket instead of adding a field of its own.
    METHODS = %w[initialize notifications/cancelled notifications/initialized ping server/discover tools/call tools/list].freeze
    UNDECLARED = "undeclared"
    OTHER = "other"
    RETENTION = 90.days
    SEPARATOR = "|"
    # A declared revision is client-supplied too: a version-shaped value is kept as sent, and a
    # day's counter set is capped so no caller can grow the hash without bound.
    VERSION = /\A\d{4}-\d{2}-\d{2}\z/
    MAX_FIELDS = 200

    class << self
      # Best-effort: telemetry is never the reason a connector request fails.
      def record(connector:, declared_version:, method:)
        connector = connector.to_s
        return unless CONNECTORS.include?(connector)

        key = RedisKey.mcp_protocol_requests(Date.current)
        field = field(connector, declared_version, method)
        count = $redis.hincrby(key, field, 1)
        # Every write carries the retention, so a day that ever lost its expiry gets it back.
        $redis.expire(key, RETENTION.to_i)
        # Past the cap a new field is dropped; the counters already there keep counting.
        $redis.hdel(key, field) if count == 1 && $redis.hlen(key) > MAX_FIELDS
      rescue StandardError => e
        Rails.logger.warn("mcp_protocol_telemetry_failed #{e.class}: #{e.message}")
      end

      # connector => declared version => JSON-RPC method => requests
      def mix(date: Date.current)
        $redis.hgetall(RedisKey.mcp_protocol_requests(date)).each_with_object({}) do |(field, count), mix|
          connector, version, method = field.split(SEPARATOR, 3)
          mix[connector] ||= {}
          mix[connector][version] ||= {}
          mix[connector][version][method] = count.to_i
        end
      end

      private
        def field(connector, declared_version, method)
          [connector, version_bucket(declared_version), method_bucket(method)].join(SEPARATOR)
        end

        def version_bucket(value)
          value = value.to_s.strip
          return UNDECLARED if value.empty?

          VERSION.match?(value) ? value : OTHER
        end

        def method_bucket(value)
          value = value.to_s
          METHODS.include?(value) ? value : OTHER
        end
    end
  end
end
