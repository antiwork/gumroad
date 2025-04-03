# frozen_string_literal: true

class DropReceiptsTable < ActiveRecord::Migration
  def up
    drop_table :receipts
  end

  def down
  end
end
