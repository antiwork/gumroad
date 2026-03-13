# frozen_string_literal: true

class EnableFlatFeeOnAllSubscriptions < ActiveRecord::Migration[7.1]
  def up
    # flat_fee_applicable = flag position 4 = bitmask value 2^(4-1) = 8
    # Batch in groups of 10,000 to avoid long-running locks on MySQL
    loop do
      affected = update("UPDATE subscriptions SET flags = flags | 8 WHERE (flags & 8) = 0 LIMIT 10000")
      break if affected.zero?
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
