# frozen_string_literal: true

module WithMaxExecutionTime
  # NOTE: Rails >= 6.0.0.rc1 supports Optimizer hints. Consider using them instead if available.

  class QueryTimeoutError < Timeout::Error; end
  QUERY_TIMEOUT_MESSAGE = "maximum statement execution time exceeded"
  private_constant :QUERY_TIMEOUT_MESSAGE

  def self.query_timeout_error?(error)
    error.message.include?(QUERY_TIMEOUT_MESSAGE)
  end

  def self.timeout_queries(seconds:)
    connection = ActiveRecord::Base.connection
    previous_max_execution_time = connection.execute("select @@max_execution_time").to_a[0][0]
    max_execution_time = (seconds * 1000).to_i
    connection.execute("set max_execution_time = #{max_execution_time}")
    yield
  rescue ActiveRecord::StatementInvalid => e
    if query_timeout_error?(e)
      raise QueryTimeoutError.new(e.message)
    else
      raise
    end
  ensure
    connection.execute("set max_execution_time = #{previous_max_execution_time}")
  end
end
