# frozen_string_literal: true

class ApplicationRecord < ActiveRecord::Base
  include StrippedFields

  self.abstract_class = true

  # Worker processes (Sidekiq/rpush/anycable) set USE_DB_WORKER_REPLICAS=true.
  # mysql2_proxy then sends SELECTs to primary_replica and writes to primary.
  # Web/Puma leave the flag unset; connected_to(role: :writing) is then a no-op.
  if ENV["USE_DB_WORKER_REPLICAS"] == "true"
    connects_to database: { writing: :primary, reading: :primary_replica }
  end
end
