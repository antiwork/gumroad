# frozen_string_literal: true

module Mcp
  # Counts who calls the MCP endpoint on which revision: one counter per connector path, declared
  # protocol version (or none) and method. Kept in Redis so a client that has moved is visible from
  # `Mcp::ProtocolTelemetry.mix` without a table or a metrics vendor.
  #
  # Every bucket comes from a closed list, so a day holds at most CONNECTORS × VERSIONS × METHODS
  # fields and no client-supplied string is ever stored.
  #
  # A second counter counts tool calls: connector, tool and outcome, read with `tool_mix`. That is
  # the only place the surface says what creators actually DO through an assistant — publishing
  # versus reading sales — because the MCP route logs nothing per request anywhere else.
  module ProtocolTelemetry
    CONNECTORS = %w[muse claude chatgpt cursor antigravity].freeze
    # Every published revision, so a client declaring one we do not serve is still named.
    VERSIONS = (Server::SUPPORTED_VERSIONS + %w[2024-11-05 2025-06-18 2025-11-25]).uniq.freeze
    # The methods this endpoint dispatches.
    METHODS = (%w[initialize notifications/cancelled notifications/initialized ping server/discover tools/call tools/list] + Events::METHODS).freeze
    # The tools this endpoint serves, so a tool count stays a closed list too. A name the server no
    # longer advertises is counted as OTHER rather than dropped: a client calling a retired name is
    # exactly what the counter is for. spec/services/mcp/protocol_telemetry_spec.rb fails if this
    # list and the tool definitions drift apart.
    TOOLS = %w[
      add_content_link add_cover add_file create_bundle create_discount_code create_draft_product
      expire_discount_code get_account get_analytics get_customers get_product get_sales_totals
      get_subscriptions list_categories list_files list_payouts list_products list_purchases list_sales
      publish_product search_products unpublish_product update_bundle update_discount_code update_product
    ].freeze
    OUTCOMES = %w[ok error scope invalid].freeze
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

      # The tool|outcome part of a tool-call field, on the same closed-list rule as `bucket`.
      def tool_bucket(tool, outcome)
        [TOOLS.include?(tool.to_s) ? tool.to_s : OTHER, OUTCOMES.include?(outcome.to_s) ? outcome.to_s : OTHER].join(SEPARATOR)
      end

      # One write per HTTP request. Best-effort: telemetry is never the reason a connector request fails.
      # Returns whether the write landed, so the caller can skip a second write down the same
      # stalled connection instead of waiting out a second timeout.
      def record(connector, counts)
        return true if counts.empty? || !CONNECTORS.include?(connector.to_s)

        pairs = counts.flat_map { |bucket, count| ["#{connector}#{SEPARATOR}#{bucket}", count] }
        redis.eval(INCREMENT_SCRIPT, keys: [RedisKey.mcp_protocol_requests(Date.current)], argv: [RETENTION.to_i, *pairs])
        true
      rescue StandardError => e
        Rails.logger.warn("mcp_protocol_telemetry_failed #{e.class}")
        false
      end

      # One write per tools/call, on the same best-effort rule: a stalled Redis never changes the
      # response the creator's assistant sees.
      def record_tools(connector, counts)
        return if counts.empty? || !CONNECTORS.include?(connector.to_s)

        pairs = counts.flat_map { |bucket, count| ["#{connector}#{SEPARATOR}#{bucket}", count] }
        redis.eval(INCREMENT_SCRIPT, keys: [RedisKey.mcp_tool_calls(Date.current)], argv: [RETENTION.to_i, *pairs])
      rescue StandardError => e
        Rails.logger.warn("mcp_tool_telemetry_failed #{e.class}")
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

      # connector => tool => outcome => calls, so the report can say whether creators use the
      # sell-side tools (create, edit, publish) or only the read-side ones (sales, payouts).
      #
      # Two caveats when reconciling with `mix`: `error` includes a tool's own argument rejections
      # (a missing price answers -32602 from inside the tool), and a write that timed out after
      # Redis applied it leaves the protocol counts without the tool counts. Both are best effort.
      def tool_mix(date: Date.current)
        redis.hgetall(RedisKey.mcp_tool_calls(date)).each_with_object({}) do |(field, count), mix|
          connector, tool, outcome = field.split(SEPARATOR, 3)
          mix[connector] ||= {}
          mix[connector][tool] ||= {}
          mix[connector][tool][outcome] = count.to_i
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
