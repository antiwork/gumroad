# frozen_string_literal: true

module Mysql2ProxyRouting
  module ScopedRoles
    private
      def connection_class
        # Rails normalizes the primary application's descriptor to Base, but its
        # connected_to entries and write guards still belong to ApplicationRecord.
        if primary_connection.connection_descriptor.primary_class? && ApplicationRecord.connection_class?
          ApplicationRecord
        else
          super
        end
      end

      def top_of_connection_stack_role
        connected_to_stack.reverse_each do |entry|
          next unless entry[:klasses].include?(ActiveRecord::Base) || entry[:klasses].include?(connection_class)
          return entry[:role] if entry[:role]
        end
        nil
      end

      def connected_to(role:, &block)
        return block.call unless connection_class.respond_to?(:connected_to)

        connection_class.connected_to(role:, prevent_writes: connection_class.current_preventing_writes, &block)
      end
  end

  module ServingPoolCache
    def select_all(arel, name = nil, binds = [], **options)
      arel = arel_from_relation(arel)
      # Rails caches above the proxy dispatch. Keep the normal cache lifetime,
      # but discard results when this execution context changes serving pools.
      proxy.send(:appropriate_connection, to_sql(arel, binds)) do |connection|
        if query_cache_enabled && !query_cache.instance_variable_get(:@mysql2_proxy_connection).equal?(connection)
          clear_query_cache
          query_cache.instance_variable_set(:@mysql2_proxy_connection, connection)
        end
        super
      end
    end
  end
end
