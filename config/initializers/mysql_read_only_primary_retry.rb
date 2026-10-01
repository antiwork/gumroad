# frozen_string_literal: true

# After an RDS failover or blue/green switchover, pooled connections stay on the old
# primary, which rejects writes with 1290 before running them. Outside a transaction,
# reconnect (re-resolving DNS) and run the statement once more.
module MysqlReadOnlyPrimaryRetry
  ER_OPTION_PREVENTS_STATEMENT = 1290
  READ_ONLY_MESSAGE = /running with the --(super-)?read-only option/
  RETRY_BACKOFF = 0.1

  def self.read_only_error?(exception)
    error = exception.is_a?(::Mysql2::Error) ? exception : exception.cause
    error.is_a?(::Mysql2::Error) &&
      error.error_number == ER_OPTION_PREVENTS_STATEMENT &&
      READ_ONLY_MESSAGE.match?(error.message)
  end

  private
    def raw_execute(sql, *args, **kwargs, &block)
      super
    rescue ActiveRecord::StatementInvalid => error
      raise if replica? || !MysqlReadOnlyPrimaryRetry.read_only_error?(error)

      # The transaction's earlier statements die with the connection, so only
      # keep the connection from being handed out again.
      @read_only_primary_connection = true
      raise if transaction_open? || kwargs[:batch]

      begin
        sleep RETRY_BACKOFF
        reconnect!
      rescue StandardError
        raise error
      end
      result = super
      @read_only_primary_connection = false
      result
    end

    def discard_read_only_primary_connection
      return unless @read_only_primary_connection

      disconnect!
      @read_only_primary_connection = false
    rescue StandardError
      nil
    end
end

ActiveSupport.on_load(:active_record_mysql2adapter) do
  prepend MysqlReadOnlyPrimaryRetry
  set_callback :checkin, :after, :discard_read_only_primary_connection
end
