# frozen_string_literal: true

ActiveRecordProxyAdapters.configure do |config|
  # Same as the gem's own default (DatabaseConfiguration::PROXY_DELAY), restated
  # here because this is the knob to turn: after any write, every read on that
  # thread goes to the primary for this long. It is a cushion, not a guarantee —
  # it has never been measured against production replica lag, and a read that
  # must see fresh state needs an explicit writing block regardless.
  config.proxy_delay = 2.seconds
end

# The gem recognizes a locking read with /\A\s*select.+for update\Z/i. Query log tags
# append a comment after `FOR UPDATE`, so the match fails and every `lock!`/`with_lock`
# read is routed to the replica — with no error, because MySQL still classes it as a
# read. Fail at boot instead of discovering it as stale rows under a lock that isn't held.
if ENV["USE_DB_WORKER_REPLICAS"] == "true" && Rails.application.config.active_record.query_log_tags_enabled
  raise "query_log_tags_enabled breaks mysql2_proxy's SELECT ... FOR UPDATE routing (config/initializers/active_record_proxy_adapters.rb)"
end
