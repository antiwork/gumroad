# frozen_string_literal: true

class AddReplacementIdToProductBuildPlaySessions < ActiveRecord::Migration[8.1]
  # 20261225000001 gained this column after it had already run on some databases, which keep it
  # recorded and so never get the column from it. A database created since has it already.
  def up
    return if column_exists?(:product_build_play_sessions, :replacement_id)

    add_column :product_build_play_sessions, :replacement_id, :bigint
  end

  # The column may have come from 20261225000001, so rollback leaves it; rolling that one back drops
  # the table.
  def down
  end
end
