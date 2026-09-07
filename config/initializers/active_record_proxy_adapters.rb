# frozen_string_literal: true

ActiveRecordProxyAdapters.configure do |config|
  # Same as the gem's own default (DatabaseConfiguration::PROXY_DELAY), restated
  # here because this is the knob to turn: after any write, every read on that
  # thread goes to the primary for this long. It is a cushion, not a guarantee —
  # it has never been measured against production replica lag, and a read that
  # must see fresh state needs an explicit writing block regardless.
  config.proxy_delay = 2.seconds
end
