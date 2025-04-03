# frozen_string_literal: true

class IndexReceipts < ActiveRecord::Migration
  def up
    add_index :receipts, :purchase_id
  end

  def down
    remove_index :receipts, :purchase_id
  end
end
