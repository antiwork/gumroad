# frozen_string_literal: true

module QueryCountHelpers
  # Counts the SQL statements the block sends to the database, without schema lookups, transaction
  # statements, or query-cache hits. Pass `matching:` to count only the statements that match a pattern.
  def count_queries(matching: nil, &block)
    count = 0
    counter = lambda do |*, payload|
      next if %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:cached]
      count += 1 if matching.nil? || payload[:sql].match?(matching)
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    count
  end
end
