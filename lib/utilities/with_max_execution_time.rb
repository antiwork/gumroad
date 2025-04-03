# frozen_string_literal: true

module WithMaxExecutionTime
  # NOTE: Rails >= 6.0.0.rc1 supports Optimizer hints. Consider using them instead if available.

  class QueryTimeoutError < Timeout::Error; end

  def self.timeout_queries(seconds:)
    connection = ActiveRecord::Base.connection
    previous_max_execution_time = connection.execute("select @@max_execution_time").to_a[0][0]
    max_execution_time = (seconds * 1000).to_i
    connection.execute("set max_execution_time = #{max_execution_time}")
    yield
  rescue ActiveRecord::StatementInvalid => e
    if e.message.include?("maximum statement execution time exceeded")
      raise QueryTimeoutError.new(e.message)
    else
      raise
    end
  ensure
    connection.execute("set max_execution_time = #{previous_max_execution_time}")
  end
end
