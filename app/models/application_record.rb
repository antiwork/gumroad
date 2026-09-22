# frozen_string_literal: true

class ApplicationRecord < ActiveRecord::Base
  include StrippedFields

  self.abstract_class = true

  # Worker processes (Sidekiq/rpush/anycable) set USE_DB_WORKER_REPLICAS=true.
  # mysql2_proxy then sends SELECTs to primary_replica and writes to primary.
  #
  # Web/Puma leave the flag unset, and then BOTH roles are a silent no-op, not an
  # error: without connects_to nothing sets `connection_class`, so
  # connection_class_for_self resolves to ActiveRecord::Base, no connected_to_stack
  # entry ever matches, and current_role/current_preventing_writes fall through to
  # :writing/false. So `connected_to(role: :reading)` reads the primary and does not
  # prevent writes — which is why DatabaseRoleRouting#with_replica_database checks
  # this method instead of relying on the role to fail.
  def self.replica_roles_configured?
    ENV["USE_DB_WORKER_REPLICAS"] == "true"
  end

  connects_to database: { writing: :primary, reading: :primary_replica } if replica_roles_configured?
end
