# frozen_string_literal: true

# Chooses the database role for a block. On worker processes with
# USE_DB_WORKER_REPLICAS these are the writing/reading roles; elsewhere there
# are no replica roles and both helpers just yield.
module DatabaseRoleRouting
  private
    # Reads that must see freshly committed state.
    def with_primary_database(pinned = true, &block)
      return yield unless pinned

      ApplicationRecord.connected_to(role: :writing, &block)
    end

    # The inverse: keeps an expensive, lag-tolerant scan on the replica even
    # when a write just happened, which mysql2_proxy's proxy_delay window would
    # otherwise route to the primary. Reads only — the reading role sets
    # prevent_writes, so a write in here raises ReadOnlyError.
    def with_replica_database(&block)
      return yield unless ApplicationRecord.replica_roles_configured?

      ApplicationRecord.connected_to(role: :reading, &block)
    end
end
