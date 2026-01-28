# frozen_string_literal: true

class DropReceiptsTable < ActiveRecord::Migration[4.2]
  def up
    drop_table :receipts
  end

  def down
  end
end
