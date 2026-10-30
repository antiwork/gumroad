# frozen_string_literal: true

class WidenPurchasesJsonData < ActiveRecord::Migration[8.1]
  JSON_DATA_LIMIT = 4096
  MAX_ATTEMPTS = 5

  # The 2-byte length prefix stays, so INPLACE only changes metadata, where Alterity's pt-osc would
  # copy every row. ALGORITHM/LOCK make MySQL refuse rather than copy, and lock_wait_timeout=1 (as in
  # InstantDdlFirst) keeps the metadata-lock wait from queuing purchases queries. Any transaction that
  # has touched purchases for over a second blocks that lock, so a timeout is retried, not fatal.
  def up
    # Databases that ran the superseded 20261222000004 already hold json_data as LONGTEXT, and
    # TEXT -> VARCHAR is never in place.
    return if column_exists?(:purchases, :json_data, :text)

    Alterity.disable do
      previous_lock_wait_timeout = connection.select_value("SELECT @@SESSION.lock_wait_timeout")
      execute("SET SESSION lock_wait_timeout = 1")
      begin
        execute("ALTER TABLE purchases MODIFY json_data varchar(#{JSON_DATA_LIMIT}), ALGORITHM=INPLACE, LOCK=NONE")
      rescue ActiveRecord::LockWaitTimeout
        attempts = (attempts || 1) + 1
        raise if attempts > MAX_ATTEMPTS

        say("Metadata lock wait timed out, attempt #{attempts}/#{MAX_ATTEMPTS}")
        sleep(attempts)
        retry
      end
    ensure
      execute("SET SESSION lock_wait_timeout = #{previous_lock_wait_timeout.to_i}") if previous_lock_wait_timeout
    end
  end

  # Narrowing back to varchar(255) would cut every longer value this column now holds.
  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
