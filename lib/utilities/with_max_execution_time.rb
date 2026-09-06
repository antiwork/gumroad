# frozen_string_literal: true

module WithMaxExecutionTime
  # NOTE: Rails >= 6.0.0.rc1 supports Optimizer hints. Consider using them instead if available.

  class QueryTimeoutError < Timeout::Error; end

  def self.timeout_queries(seconds:)
    max_execution_time = (seconds * 1000).to_i
    previous_by_role = {}

    apply_max_execution_time(:writing, max_execution_time, previous_by_role)
    apply_max_execution_time(:reading, max_execution_time, previous_by_role) if replica_roles_configured?

    yield
  rescue ActiveRecord::StatementInvalid => e
    if e.message.include?("maximum statement execution time exceeded")
      raise QueryTimeoutError.new(e.message)
    else
      raise
    end
  ensure
    previous_by_role.each do |role, previous_max_execution_time|
      restore_max_execution_time(role, previous_max_execution_time)
    end
  end

  def self.replica_roles_configured?
    ENV["USE_DB_WORKER_REPLICAS"] == "true"
  end
  private_class_method :replica_roles_configured?

  def self.apply_max_execution_time(role, max_execution_time, previous_by_role)
    with_role(role) do |connection|
      previous_by_role[role] = connection.execute("select @@max_execution_time").to_a[0][0]
      connection.execute("set max_execution_time = #{max_execution_time}")
    end
  end
  private_class_method :apply_max_execution_time

  def self.restore_max_execution_time(role, previous_max_execution_time)
    with_role(role) do |connection|
      connection.execute("set max_execution_time = #{previous_max_execution_time}")
    end
  rescue ActiveRecord::StatementInvalid, Mysql2::Error => e
    Rails.logger.error("[WithMaxExecutionTime] Failed to restore max_execution_time: #{e.message}")
  end
  private_class_method :restore_max_execution_time

  def self.with_role(role, &block)
    if role == :writing && !replica_roles_configured?
      yield ActiveRecord::Base.connection
    else
      ApplicationRecord.connected_to(role: role) { yield ApplicationRecord.connection }
    end
  end
  private_class_method :with_role
end
