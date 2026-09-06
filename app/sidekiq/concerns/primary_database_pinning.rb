# frozen_string_literal: true

# Runs the block on the primary database when `pinned` is true. Without
# `connects_to` replicas configured, `connected_to(role: :writing)` just yields.
module PrimaryDatabasePinning
  private
    def with_primary_database(pinned = true, &block)
      return yield unless pinned

      ApplicationRecord.connected_to(role: :writing, &block)
    end
end
