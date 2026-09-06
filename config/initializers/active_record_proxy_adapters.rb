# frozen_string_literal: true

ActiveRecordProxyAdapters.configure do |config|
  # A bounded cushion for replication lag, not a job-wide consistency guarantee.
  # Reads requiring fresh state must still use an explicit writing block.
  config.proxy_delay = 2.seconds
end
