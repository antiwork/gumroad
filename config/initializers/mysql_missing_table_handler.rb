# frozen_string_literal: true

module Mysql2
  class Client
    MISSING_TABLE_GRACE_PERIOD = 5.seconds

    alias original_query query
    def query(sql, options = {})
      original_query(sql, options)
    rescue Mysql2::Error => e
      raise unless /Table .* doesn't exist/.match?(e.message)
      warn "Error: missing table, retrying in #{MISSING_TABLE_GRACE_PERIOD} seconds..."
      sleep MISSING_TABLE_GRACE_PERIOD
      original_query(sql, options)
    end
  end
end
