# frozen_string_literal: true

module Muse
  # Counts who calls the MCP endpoint on which revision: one counter per connector path, declared
  # protocol version (or none) and method. Kept in Redis so a client that has moved is visible from
  # `Muse::ProtocolTelemetry.mix` without a table or a metrics vendor.
  module ProtocolTelemetry
    CONNECTORS = %w[muse claude chatgpt].freeze
    UNDECLARED = "undeclared"
    OTHER = "other"
    RETENTION = 90.days
    SEPARATOR = "|"
    # A declaration and a method are client-supplied, so only shape-valid values get a counter of
    # their own; everything else shares one bucket rather than growing the hash without bound.
    VERSION = /\A\d{4}-\d{2}-\d{2}\z/
    METHOD = %r{\A[a-z][a-z0-9_-]*(?:/[a-z][a-z0-9_-]*)*\z}

    class << self
      # Best-effort: telemetry is never the reason a connector request fails.
      def record(connector:, declared_version:, method:)
        connector = connector.to_s
        return unless CONNECTORS.include?(connector)

        key = RedisKey.mcp_protocol_requests(Date.current)
        count = $redis.hincrby(key, field(connector, declared_version, method), 1)
        $redis.expire(key, RETENTION.to_i) if count == 1
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
          METHOD.match?(value) && value.length <= 64 ? value : OTHER
        end
    end
  end
end
