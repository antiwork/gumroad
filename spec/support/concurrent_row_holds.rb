# frozen_string_literal: true

require "timeout"

# For examples that run outside the fixture transaction and need a row held from another
# connection while the example runs.
module ConcurrentRowHolds
  HOLD_TIMEOUT_SECONDS = 10

  def in_thread(&block)
    Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }
  end

  # Runs `hold` on another connection inside a transaction that stays open while the block runs.
  def while_held_elsewhere(hold)
    held = Queue.new
    release = Queue.new
    holder = in_thread do
      ActiveRecord::Base.transaction do
        hold.call
        held << true
        release.pop
      end
    end
    Timeout.timeout(HOLD_TIMEOUT_SECONDS) { held.pop }
    yield
  ensure
    release << true
    # A holder still blocked here keeps its connection and open transaction into later examples.
    if holder && holder.join(HOLD_TIMEOUT_SECONDS).nil?
      holder.kill
      raise "Row holder thread did not stop within #{HOLD_TIMEOUT_SECONDS}s" if holder.join(HOLD_TIMEOUT_SECONDS).nil?
    end
  end
end

RSpec.configure do |config|
  config.include ConcurrentRowHolds
end
