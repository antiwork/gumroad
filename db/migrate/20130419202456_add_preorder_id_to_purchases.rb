# frozen_string_literal: true

class AddPreorderIdToPurchases < ActiveRecord::Migration
  def change
    add_column :purchases, :preorder_id, :integer
    add_index :purchases, :preorder_id
  end
end
