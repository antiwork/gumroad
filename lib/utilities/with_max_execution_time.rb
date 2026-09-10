# frozen_string_literal: true

module WithMaxExecutionTime
  # NOTE: Rails >= 6.0.0.rc1 supports Optimizer hints. Consider using them instead if available.

  class QueryTimeoutError < Timeout::Error; end

  # ConnectionTimeoutError and DatabaseConnectionError are both subclasses of
  # ConnectionNotEstablished, so pool exhaustion and auth failures are covered too.
  ROLE_UNAVAILABLE_ERRORS = [ActiveRecord::ConnectionNotEstablished, ActiveRecord::NoDatabaseError].freeze
  private_constant :ROLE_UNAVAILABLE_ERRORS

  def self.timeout_queries(seconds:)
    max_execution_time = (seconds * 1000).to_i
    previous_by_role = {}

    apply_max_execution_time(:writing, max_execution_time, previous_by_role)
    # Both roles, not just the writing one: an unpinned read can be routed to the
    # replica by mysql2_proxy, and the cap only exists on the connection it is set
    # on. SendPostBlastEmailsSliceJob's member load is exactly that — unpinned, and
    # relying on CHUNK_LOAD_TIMEOUT to keep the statement inside its Redis claim.
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
    ApplicationRecord.replica_roles_configured?
  end
  private_class_method :replica_roles_configured?

  def self.apply_max_execution_time(role, max_execution_time, previous_by_role)
    with_role(role) do |connection|
      previous_by_role[role] = connection.execute("select @@max_execution_time").to_a[0][0]
      connection.execute("set max_execution_time = #{max_execution_time}")
    end
  rescue *ROLE_UNAVAILABLE_ERRORS => e
    # In practice only the reading role reaches here: leasing from the reading pool
    # connects, and mysql2_proxy's own replica fallback does not cover a direct
    # connected_to. Losing the cap on a role that cannot serve a statement anyway must
    # not fail the ~20 jobs that wrap payouts, monthly-close reports and blasts in this
    # — none of them asked for replica routing. Drop the role and carry on; the proxy
    # falls back to the primary, which is already capped above. A dead connection also
    # makes the restore pointless, so forget it rather than log a second failure.
    previous_by_role.delete(role)
    Rails.logger.error("[WithMaxExecutionTime] Skipping #{role} role: #{e.class}: #{e.message}")
    raise if role == :writing
  end
  private_class_method :apply_max_execution_time

  def self.restore_max_execution_time(role, previous_max_execution_time)
    with_role(role) do |connection|
      connection.execute("set max_execution_time = #{previous_max_execution_time}")
    end
  rescue ActiveRecord::StatementInvalid, Mysql2::Error, *ROLE_UNAVAILABLE_ERRORS => e
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
