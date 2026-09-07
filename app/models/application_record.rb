# frozen_string_literal: true

class ApplicationRecord < ActiveRecord::Base
  include StrippedFields

  self.abstract_class = true

  # Worker processes (Sidekiq/rpush/anycable) set USE_DB_WORKER_REPLICAS=true.
  # mysql2_proxy then sends SELECTs to primary_replica and writes to primary.
  # Web/Puma leave the flag unset: there is no reading pool at all, so
  # connected_to(role: :writing) is a no-op and :reading would raise.
  def self.replica_roles_configured?
    ENV["USE_DB_WORKER_REPLICAS"] == "true"
  end

  connects_to database: { writing: :primary, reading: :primary_replica } if replica_roles_configured?
end
