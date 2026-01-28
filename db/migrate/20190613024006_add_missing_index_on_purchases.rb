# frozen_string_literal: true

class AddMissingIndexOnPurchases < ActiveRecord::Migration[4.2]
  def up
    add_index :purchases, [:link_id, :purchase_state, :created_at]
  end

  def down
    remove_index :purchases, [:link_id, :purchase_state, :created_at]
  end
end
