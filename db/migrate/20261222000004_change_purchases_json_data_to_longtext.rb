# frozen_string_literal: true

class ChangePurchasesJsonDataToLongtext < ActiveRecord::Migration[8.1]
  # The non-strict sql_mode in database.yml cuts an over-length value without an error, leaving
  # unparseable JSON. LONGTEXT holds more than max_allowed_packet can carry (1 GiB at most), so an
  # oversized write now fails on the packet limit instead of being stored truncated.
  def up
    change_column :purchases, :json_data, :text, size: :long
  end

  # Narrowing back to varchar(255) would cut every longer value this column now holds.
  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
